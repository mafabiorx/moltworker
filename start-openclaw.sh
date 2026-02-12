#!/bin/bash
# Startup script for OpenClaw in Cloudflare Sandbox (bootstrap v4)
# This script:
# 1. Restores config from R2 backup if available
# 2. Runs openclaw onboard --non-interactive to configure from env vars
# 3. Patches config for features onboard doesn't cover (channels, gateway auth)
# 4. Starts the gateway

set -e

if pgrep -f "openclaw gateway" > /dev/null 2>&1; then
    echo "OpenClaw gateway is already running, exiting."
    exit 0
fi

CONFIG_DIR="/root/.openclaw"
CONFIG_FILE="$CONFIG_DIR/openclaw.json"
BACKUP_DIR="/data/moltbot"

echo "Config directory: $CONFIG_DIR"
echo "Backup directory: $BACKUP_DIR"

mkdir -p "$CONFIG_DIR"

# ============================================================
# RESTORE FROM R2 BACKUP
# ============================================================

should_restore_from_r2() {
    local R2_SYNC_FILE="$BACKUP_DIR/.last-sync"
    local LOCAL_SYNC_FILE="$CONFIG_DIR/.last-sync"

    if [ ! -f "$R2_SYNC_FILE" ]; then
        echo "No R2 sync timestamp found, skipping restore"
        return 1
    fi

    if [ ! -f "$LOCAL_SYNC_FILE" ]; then
        echo "No local sync timestamp, will restore from R2"
        return 0
    fi

    R2_TIME=$(cat "$R2_SYNC_FILE" 2>/dev/null)
    LOCAL_TIME=$(cat "$LOCAL_SYNC_FILE" 2>/dev/null)

    echo "R2 last sync: $R2_TIME"
    echo "Local last sync: $LOCAL_TIME"

    R2_EPOCH=$(date -d "$R2_TIME" +%s 2>/dev/null || echo "0")
    LOCAL_EPOCH=$(date -d "$LOCAL_TIME" +%s 2>/dev/null || echo "0")

    if [ "$R2_EPOCH" -gt "$LOCAL_EPOCH" ]; then
        echo "R2 backup is newer, will restore"
        return 0
    else
        echo "Local data is newer or same, skipping restore"
        return 1
    fi
}

# Evaluate restore decision once, before any restore operations.
# This avoids a race where the config restore copies .last-sync into $CONFIG_DIR,
# making subsequent should_restore_from_r2 calls return false (timestamps match).
DO_RESTORE=false
if should_restore_from_r2; then
    DO_RESTORE=true
fi

# Check for backup data in new openclaw/ prefix first, then legacy clawdbot/ prefix
if [ "$DO_RESTORE" = true ] && [ -f "$BACKUP_DIR/openclaw/openclaw.json" ]; then
    echo "Restoring from R2 backup at $BACKUP_DIR/openclaw..."
    cp -a "$BACKUP_DIR/openclaw/." "$CONFIG_DIR/"
    cp -f "$BACKUP_DIR/.last-sync" "$CONFIG_DIR/.last-sync" 2>/dev/null || true
    echo "Restored config from R2 backup"
elif [ "$DO_RESTORE" = true ] && [ -f "$BACKUP_DIR/clawdbot/clawdbot.json" ]; then
    # Legacy backup format — migrate .clawdbot data into .openclaw
    echo "Restoring from legacy R2 backup at $BACKUP_DIR/clawdbot..."
    cp -a "$BACKUP_DIR/clawdbot/." "$CONFIG_DIR/"
    cp -f "$BACKUP_DIR/.last-sync" "$CONFIG_DIR/.last-sync" 2>/dev/null || true
    if [ -f "$CONFIG_DIR/clawdbot.json" ] && [ ! -f "$CONFIG_FILE" ]; then
        mv "$CONFIG_DIR/clawdbot.json" "$CONFIG_FILE"
    fi
    echo "Restored and migrated config from legacy R2 backup"
elif [ "$DO_RESTORE" = true ] && [ -f "$BACKUP_DIR/clawdbot.json" ]; then
    # Very old legacy backup format (flat structure)
    echo "Restoring from flat legacy R2 backup at $BACKUP_DIR..."
    cp -a "$BACKUP_DIR/." "$CONFIG_DIR/"
    cp -f "$BACKUP_DIR/.last-sync" "$CONFIG_DIR/.last-sync" 2>/dev/null || true
    if [ -f "$CONFIG_DIR/clawdbot.json" ] && [ ! -f "$CONFIG_FILE" ]; then
        mv "$CONFIG_DIR/clawdbot.json" "$CONFIG_FILE"
    fi
    echo "Restored and migrated config from flat legacy R2 backup"
elif [ -d "$BACKUP_DIR" ]; then
    echo "R2 mounted at $BACKUP_DIR but no backup data found yet"
else
    echo "R2 not mounted, starting fresh"
fi

# Restore workspace from R2 backup if available
# This includes IDENTITY.md, USER.md, MEMORY.md, memory/, and assets/
WORKSPACE_DIR="/root/clawd"
if [ "$DO_RESTORE" = true ] && [ -d "$BACKUP_DIR/workspace" ] && [ "$(ls -A $BACKUP_DIR/workspace 2>/dev/null)" ]; then
    echo "Restoring workspace from $BACKUP_DIR/workspace..."
    mkdir -p "$WORKSPACE_DIR"
    cp -a "$BACKUP_DIR/workspace/." "$WORKSPACE_DIR/"
    echo "Restored workspace from R2 backup"
fi

# Restore skills from R2 backup if available
SKILLS_DIR="/root/clawd/skills"
if [ "$DO_RESTORE" = true ] && [ -d "$BACKUP_DIR/skills" ] && [ "$(ls -A $BACKUP_DIR/skills 2>/dev/null)" ]; then
    echo "Restoring skills from $BACKUP_DIR/skills..."
    mkdir -p "$SKILLS_DIR"
    cp -a "$BACKUP_DIR/skills/." "$SKILLS_DIR/"
    echo "Restored skills from R2 backup"
fi

# ============================================================
# ONBOARD (only if no config exists yet)
# ============================================================
if [ ! -f "$CONFIG_FILE" ]; then
    echo "No existing config found, running openclaw onboard..."

    AUTH_ARGS=""
    if [ -n "$CLOUDFLARE_AI_GATEWAY_API_KEY" ] && [ -n "$CF_AI_GATEWAY_ACCOUNT_ID" ] && [ -n "$CF_AI_GATEWAY_GATEWAY_ID" ]; then
        AUTH_ARGS="--auth-choice cloudflare-ai-gateway-api-key \
            --cloudflare-ai-gateway-account-id $CF_AI_GATEWAY_ACCOUNT_ID \
            --cloudflare-ai-gateway-gateway-id $CF_AI_GATEWAY_GATEWAY_ID \
            --cloudflare-ai-gateway-api-key $CLOUDFLARE_AI_GATEWAY_API_KEY"
    elif [ -n "$ANTHROPIC_API_KEY" ]; then
        AUTH_ARGS="--auth-choice apiKey --anthropic-api-key $ANTHROPIC_API_KEY"
    elif [ -n "$OPENAI_API_KEY" ]; then
        AUTH_ARGS="--auth-choice openai-api-key --openai-api-key $OPENAI_API_KEY"
    fi

    openclaw onboard --non-interactive --accept-risk \
        --mode local \
        $AUTH_ARGS \
        --gateway-port 18789 \
        --gateway-bind lan \
        --skip-channels \
        --skip-skills \
        --skip-health

    echo "Onboard completed"
else
    echo "Using existing config"
fi

# ============================================================
# PATCH CONFIG (channels, gateway auth, trusted proxies)
# ============================================================
# openclaw onboard handles provider/model config, but we need to patch in:
# - Channel config (Telegram, Discord, Slack)
# - Gateway token auth
# - Trusted proxies for sandbox networking
# - Base URL override for legacy AI Gateway path
node << 'EOFPATCH'
const fs = require('fs');

const configPath = '/root/.openclaw/openclaw.json';
console.log('Patching config at:', configPath);
let config = {};

try {
    config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
} catch (e) {
    console.log('Starting with empty config');
}

config.gateway = config.gateway || {};
config.channels = config.channels || {};

// Gateway configuration
config.gateway.port = 18789;
config.gateway.mode = 'local';
config.gateway.trustedProxies = ['10.1.0.0'];

if (process.env.OPENCLAW_GATEWAY_TOKEN) {
    config.gateway.auth = config.gateway.auth || {};
    config.gateway.auth.token = process.env.OPENCLAW_GATEWAY_TOKEN;
}

if (process.env.OPENCLAW_DEV_MODE === 'true') {
    config.gateway.controlUi = config.gateway.controlUi || {};
    config.gateway.controlUi.allowInsecureAuth = true;
}

// Legacy AI Gateway base URL override:
// ANTHROPIC_BASE_URL is picked up natively by the Anthropic SDK,
// so we don't need to patch the provider config. Writing a provider
// entry without a models array breaks OpenClaw's config validation.

// AI Gateway model override (CF_AI_GATEWAY_MODEL=provider/model-id)
// Adds a provider entry for any AI Gateway provider and sets it as default model.
// Examples:
//   workers-ai/@cf/meta/llama-3.3-70b-instruct-fp8-fast
//   openai/gpt-4o
//   anthropic/claude-sonnet-4-5
if (process.env.CF_AI_GATEWAY_MODEL) {
    const raw = process.env.CF_AI_GATEWAY_MODEL;
    const slashIdx = raw.indexOf('/');
    const gwProvider = raw.substring(0, slashIdx);
    const modelId = raw.substring(slashIdx + 1);

    const accountId = process.env.CF_AI_GATEWAY_ACCOUNT_ID;
    const gatewayId = process.env.CF_AI_GATEWAY_GATEWAY_ID;
    const apiKey = process.env.CLOUDFLARE_AI_GATEWAY_API_KEY;

    let baseUrl;
    if (accountId && gatewayId) {
        baseUrl = 'https://gateway.ai.cloudflare.com/v1/' + accountId + '/' + gatewayId + '/' + gwProvider;
        if (gwProvider === 'workers-ai') baseUrl += '/v1';
    } else if (gwProvider === 'workers-ai' && process.env.CF_ACCOUNT_ID) {
        baseUrl = 'https://api.cloudflare.com/client/v4/accounts/' + process.env.CF_ACCOUNT_ID + '/ai/v1';
    }

    if (baseUrl && apiKey) {
        const api = gwProvider === 'anthropic' ? 'anthropic-messages' : 'openai-completions';
        const providerName = 'cf-ai-gw-' + gwProvider;

        config.models = config.models || {};
        config.models.providers = config.models.providers || {};
        config.models.providers[providerName] = {
            baseUrl: baseUrl,
            apiKey: apiKey,
            api: api,
            models: [{ id: modelId, name: modelId, contextWindow: 131072, maxTokens: 8192 }],
        };
        config.agents = config.agents || {};
        config.agents.defaults = config.agents.defaults || {};
        config.agents.defaults.model = { primary: providerName + '/' + modelId };
        console.log('AI Gateway model override: provider=' + providerName + ' model=' + modelId + ' via ' + baseUrl);
    } else {
        console.warn('CF_AI_GATEWAY_MODEL set but missing required config (account ID, gateway ID, or API key)');
    }
}

// Telegram configuration
// Overwrite entire channel object to drop stale keys from old R2 backups
// that would fail OpenClaw's strict config validation (see #47)
if (process.env.TELEGRAM_BOT_TOKEN) {
    const dmPolicy = process.env.TELEGRAM_DM_POLICY || 'pairing';
    config.channels.telegram = {
        botToken: process.env.TELEGRAM_BOT_TOKEN,
        enabled: true,
        dmPolicy: dmPolicy,
    };
    if (process.env.TELEGRAM_DM_ALLOW_FROM) {
        config.channels.telegram.allowFrom = process.env.TELEGRAM_DM_ALLOW_FROM.split(',');
    } else if (dmPolicy === 'open') {
        config.channels.telegram.allowFrom = ['*'];
    }
}

// Discord configuration
// Discord uses a nested dm object: dm.policy, dm.allowFrom (per DiscordDmConfig)
if (process.env.DISCORD_BOT_TOKEN) {
    const dmPolicy = process.env.DISCORD_DM_POLICY || 'pairing';
    const dm = { policy: dmPolicy };
    if (dmPolicy === 'open') {
        dm.allowFrom = ['*'];
    }
    config.channels.discord = {
        token: process.env.DISCORD_BOT_TOKEN,
        enabled: true,
        dm: dm,
    };
}

// Slack configuration
if (process.env.SLACK_BOT_TOKEN && process.env.SLACK_APP_TOKEN) {
    config.channels.slack = {
        botToken: process.env.SLACK_BOT_TOKEN,
        appToken: process.env.SLACK_APP_TOKEN,
        enabled: true,
    };
}

fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
console.log('Configuration patched successfully');
EOFPATCH

# ============================================================
# P0 VERIFICATION (pre-gateway workspace integrity check)
# ============================================================
echo "Running P0 verification..."

P0_ERRORS=0

# Check workspace directory
if [ ! -d "$WORKSPACE_DIR" ]; then
    echo "WARNING: Workspace directory $WORKSPACE_DIR missing, creating..."
    mkdir -p "$WORKSPACE_DIR"
    P0_ERRORS=$((P0_ERRORS + 1))
fi

# Check critical workspace files
for f in IDENTITY.md MEMORY.md USER.md; do
    if [ ! -f "$WORKSPACE_DIR/$f" ]; then
        echo "WARNING: $WORKSPACE_DIR/$f missing after restore"
        P0_ERRORS=$((P0_ERRORS + 1))
    fi
done

# Check skills directory has content
if [ ! -d "$SKILLS_DIR" ]; then
    echo "WARNING: Skills directory $SKILLS_DIR missing"
    P0_ERRORS=$((P0_ERRORS + 1))
else
    SKILL_COUNT=$(find "$SKILLS_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
    if [ "$SKILL_COUNT" -eq 0 ]; then
        echo "WARNING: No skills found in $SKILLS_DIR"
        P0_ERRORS=$((P0_ERRORS + 1))
    else
        echo "Skills: $SKILL_COUNT found"
    fi
fi

# Check config exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo "WARNING: Config file $CONFIG_FILE missing after onboard/restore"
    P0_ERRORS=$((P0_ERRORS + 1))
fi

# Check disk space
DISK_FREE_MB=$(df -m / 2>/dev/null | awk 'NR==2 {print $4}')
if [ -n "$DISK_FREE_MB" ] && [ "$DISK_FREE_MB" -eq "$DISK_FREE_MB" ] 2>/dev/null; then
    echo "Disk free: ${DISK_FREE_MB}MB"
    if [ "$DISK_FREE_MB" -lt 500 ]; then
        echo "WARNING: Low disk space (${DISK_FREE_MB}MB free)"
    fi
fi

if [ "$P0_ERRORS" -gt 0 ]; then
    echo "P0 verification completed with $P0_ERRORS warning(s)"
else
    echo "P0 verification passed"
fi

# ============================================================
# BOOTSTRAP (run in background on fresh rootfs)
# ============================================================
# The bootstrap installs tools (python3, rclone, uv, amp, etc.) that
# survive only on rootfs. After a cold restart the rootfs is wiped but
# the .bootstrap-complete marker may survive in the R2-backed workspace.
# Use python3 absence as the definitive canary for fresh rootfs.
if ! command -v python3 &>/dev/null && [ -f "$WORKSPACE_DIR/.bootstrap.sh" ]; then
    echo "Fresh rootfs detected (python3 missing). Running bootstrap in background..."
    # Source HAL storage credentials for rclone cache access
    [ -f "$BACKUP_DIR/.hal_storage_env" ] && . "$BACKUP_DIR/.hal_storage_env"
    bash "$WORKSPACE_DIR/.bootstrap.sh" > /tmp/bootstrap.log 2>&1 &
    echo "Bootstrap started (PID: $!), log at /tmp/bootstrap.log"
elif ! command -v python3 &>/dev/null; then
    echo "WARNING: python3 missing but no .bootstrap.sh found — first boot?"
else
    echo "Rootfs tools present (python3 found), skipping bootstrap"
fi

# ============================================================
# START GATEWAY
# ============================================================
echo "Starting OpenClaw Gateway..."
echo "Gateway will be available on port 18789"

rm -f /tmp/openclaw-gateway.lock 2>/dev/null || true
rm -f "$CONFIG_DIR/gateway.lock" 2>/dev/null || true

echo "Dev mode: ${OPENCLAW_DEV_MODE:-false}"

if [ -n "$OPENCLAW_GATEWAY_TOKEN" ]; then
    echo "Starting gateway with token auth..."
    exec openclaw gateway --port 18789 --verbose --allow-unconfigured --bind lan --token "$OPENCLAW_GATEWAY_TOKEN"
else
    echo "Starting gateway with device pairing (no token)..."
    exec openclaw gateway --port 18789 --verbose --allow-unconfigured --bind lan
fi
