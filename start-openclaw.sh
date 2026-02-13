#!/bin/bash
# Startup script for OpenClaw in Cloudflare Sandbox (bootstrap v4 + rclone)
# This script:
# 1. Sets up rclone for R2 access
# 2. Restores config from R2 backup if available (via rclone)
# 3. Runs openclaw onboard --non-interactive to configure from env vars
# 4. Patches config for features onboard doesn't cover (channels, gateway auth)
# 5. Starts background sync loop
# 6. Starts the gateway

set -e

if pgrep -f "openclaw gateway" > /dev/null 2>&1 || pgrep -f "openclaw-gateway" > /dev/null 2>&1; then
    echo "OpenClaw gateway is already running, exiting."
    exit 0
fi

CONFIG_DIR="/root/.openclaw"
CONFIG_FILE="$CONFIG_DIR/openclaw.json"

echo "Config directory: $CONFIG_DIR"

mkdir -p "$CONFIG_DIR"

# ============================================================
# RCLONE SETUP
# ============================================================
RCLONE_BUCKET="${R2_BUCKET_NAME:-moltbot-data}"
RCLONE_REMOTE="r2:${RCLONE_BUCKET}"

setup_rclone() {
    if [ -z "$R2_ACCESS_KEY_ID" ] || [ -z "$R2_SECRET_ACCESS_KEY" ] || [ -z "$CF_ACCOUNT_ID" ]; then
        echo "R2 credentials not set, skipping rclone setup"
        return 1
    fi
    mkdir -p /root/.config/rclone
    cat > /root/.config/rclone/rclone.conf << EOF
[r2]
type = s3
provider = Cloudflare
access_key_id = ${R2_ACCESS_KEY_ID}
secret_access_key = ${R2_SECRET_ACCESS_KEY}
endpoint = https://${CF_ACCOUNT_ID}.r2.cloudflarestorage.com
acl = private
EOF
    return 0
}

RCLONE_AVAILABLE=false
if setup_rclone; then
    RCLONE_AVAILABLE=true
    echo "rclone configured for R2 bucket: $RCLONE_BUCKET"
fi

# ============================================================
# RESTORE FROM R2 BACKUP (via rclone)
# ============================================================

should_restore_from_r2() {
    [ "$RCLONE_AVAILABLE" = true ] || return 1

    local R2_TIME
    R2_TIME=$(rclone cat "$RCLONE_REMOTE/.last-sync" 2>/dev/null) || true
    if [ -z "$R2_TIME" ]; then
        echo "No R2 sync timestamp found, skipping restore"
        return 1
    fi

    local LOCAL_TIME
    LOCAL_TIME=$(cat "$CONFIG_DIR/.last-sync" 2>/dev/null) || true
    if [ -z "$LOCAL_TIME" ]; then
        echo "No local sync timestamp, will restore from R2"
        return 0
    fi

    echo "R2 last sync: $R2_TIME"
    echo "Local last sync: $LOCAL_TIME"

    local R2_EPOCH LOCAL_EPOCH
    R2_EPOCH=$(date -d "$R2_TIME" +%s 2>/dev/null || echo "0")
    LOCAL_EPOCH=$(date -d "$LOCAL_TIME" +%s 2>/dev/null || echo "0")

    [ "$R2_EPOCH" -gt "$LOCAL_EPOCH" ]
}

# Evaluate restore decision once, before any restore operations.
# This avoids a race where the config restore copies .last-sync into $CONFIG_DIR,
# making subsequent should_restore_from_r2 calls return false (timestamps match).
DO_RESTORE=false
if should_restore_from_r2; then
    DO_RESTORE=true
fi

if [ "$DO_RESTORE" = true ]; then
    # Check for backup data: new openclaw/ prefix, then legacy clawdbot/
    if rclone ls "$RCLONE_REMOTE/openclaw/openclaw.json" &>/dev/null; then
        echo "Restoring config from R2 (openclaw format)..."
        rclone copy "$RCLONE_REMOTE/openclaw/" "$CONFIG_DIR/" --transfers=8 --fast-list
        rclone cat "$RCLONE_REMOTE/.last-sync" > "$CONFIG_DIR/.last-sync" 2>/dev/null || true
        echo "Restored config from R2 backup"
    elif rclone ls "$RCLONE_REMOTE/clawdbot/clawdbot.json" &>/dev/null; then
        echo "Restoring config from R2 (legacy clawdbot format)..."
        rclone copy "$RCLONE_REMOTE/clawdbot/" "$CONFIG_DIR/" --transfers=8 --fast-list
        rclone cat "$RCLONE_REMOTE/.last-sync" > "$CONFIG_DIR/.last-sync" 2>/dev/null || true
        [ -f "$CONFIG_DIR/clawdbot.json" ] && [ ! -f "$CONFIG_FILE" ] && mv "$CONFIG_DIR/clawdbot.json" "$CONFIG_FILE"
        echo "Restored and migrated config from legacy R2 backup"
    elif rclone ls "$RCLONE_REMOTE/clawdbot.json" &>/dev/null; then
        echo "Restoring config from R2 (flat legacy format)..."
        rclone copy "$RCLONE_REMOTE/" "$CONFIG_DIR/" --transfers=8 --fast-list \
            --include 'clawdbot.json' --include '*.db' --include '.last-sync'
        [ -f "$CONFIG_DIR/clawdbot.json" ] && [ ! -f "$CONFIG_FILE" ] && mv "$CONFIG_DIR/clawdbot.json" "$CONFIG_FILE"
        echo "Restored and migrated config from flat legacy R2 backup"
    else
        echo "R2 accessible but no backup data found"
    fi

    # Restore workspace
    WORKSPACE_DIR="/root/clawd"
    if rclone ls "$RCLONE_REMOTE/workspace/" &>/dev/null 2>&1; then
        echo "Restoring workspace from R2..."
        mkdir -p "$WORKSPACE_DIR"
        rclone copy "$RCLONE_REMOTE/workspace/" "$WORKSPACE_DIR/" --transfers=8 --fast-list
        echo "Restored workspace from R2 backup"
    fi

    # Restore skills
    SKILLS_DIR="/root/clawd/skills"
    if rclone ls "$RCLONE_REMOTE/skills/" &>/dev/null 2>&1; then
        echo "Restoring skills from R2..."
        mkdir -p "$SKILLS_DIR"
        rclone copy "$RCLONE_REMOTE/skills/" "$SKILLS_DIR/" --transfers=8 --fast-list
        echo "Restored skills from R2 backup"
    fi
elif [ "$RCLONE_AVAILABLE" = true ]; then
    echo "Local data is current, skipping restore"
else
    echo "R2 not configured, starting fresh"
fi

# Define workspace/skills dirs (may not have been set above if restore was skipped)
WORKSPACE_DIR="/root/clawd"
SKILLS_DIR="/root/clawd/skills"

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
# LOCAL EXTENSIONS (plugins)
# ============================================================
# Write the extension into OpenClaw's state dir at runtime.
# Important: this must happen AFTER an R2 restore, since restoring /root/.openclaw
# can overwrite the extensions directory with older copies.
EXT_DST_BASE="$CONFIG_DIR/extensions"
TRACE_EXT_DIR="$EXT_DST_BASE/trace-model"
mkdir -p "$TRACE_EXT_DIR"

# Manifest
cat > "$TRACE_EXT_DIR/openclaw.plugin.json" << 'EOF'
{
  "schemaVersion": "1.0",
  "id": "trace-model",
  "name": "Trace Model",
  "version": "0.1.1",
  "description": "Toggle Telegram model trace prefix via /trace",
  "entry": "index.js",
  "configSchema": {
    "type": "object",
    "properties": {},
    "additionalProperties": false
  }
}
EOF

# Plugin entry (ESM)
cat > "$TRACE_EXT_DIR/index.js" << 'EOF'
import fs from 'node:fs';
import path from 'node:path';

// build: 2026-02-13-trace-fix-args-v1

const CONFIG_PATH = '/root/.openclaw/openclaw.json';
const STATE_PATH = '/root/.openclaw/trace-model.state.json';
const TRACE_PREFIX = '[{model}] ';

function readJsonFile(p) {
  const raw = fs.readFileSync(p, 'utf8');
  return JSON.parse(raw);
}

function writeJsonFileAtomic(p, value) {
  fs.mkdirSync(path.dirname(p), { recursive: true });
  const tmp = `${p}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(value, null, 2) + '\\n', 'utf8');
  fs.renameSync(tmp, p);
}

function getTelegramPrefix(config) {
  return String(config?.channels?.telegram?.responsePrefix || '');
}

function setTelegramPrefix(config, prefix) {
  config.channels = config.channels || {};
  config.channels.telegram = config.channels.telegram || {};
  config.channels.telegram.responsePrefix = prefix;
}

function loadState() {
  try {
    return readJsonFile(STATE_PATH) || {};
  } catch {
    return {};
  }
}

function saveState(state) {
  writeJsonFileAtomic(STATE_PATH, state);
}

function normalizeArg(arg) {
  const a = String(arg || '').trim().toLowerCase();
  if (a === 'on') return 'on';
  if (a === 'off') return 'off';
  return 'status';
}

function firstWord(args) {
  if (Array.isArray(args)) return args[0];
  if (typeof args === 'string') return args.trim().split(/\\s+/)[0];
  return undefined;
}

export default function traceModelPlugin(api) {
  api.registerCommand({
    name: 'trace',
    description: 'Toggle Telegram model prefix tracing. Usage: /trace on|off|status',
    acceptsArgs: true,
    requireAuth: true,
    handler: async (ctx) => {
      let config;
      try {
        config = readJsonFile(CONFIG_PATH);
      } catch (err) {
        return { text: `trace: failed to read config at ${CONFIG_PATH}: ${err?.message || String(err)}` };
      }

      const state = loadState();
      const action = normalizeArg(firstWord(ctx?.args));
      const currentPrefix = getTelegramPrefix(config);

      if (action === 'status') {
        const enabled = currentPrefix.trim().length > 0;
        return {
          text: `trace: ${enabled ? 'ON' : 'OFF'} (telegram responsePrefix=${JSON.stringify(currentPrefix)}). Use: /trace on|off`,
        };
      }

      if (action === 'on') {
        if (state.previousTelegramPrefix === undefined) {
          state.previousTelegramPrefix = currentPrefix;
          saveState(state);
        }
        setTelegramPrefix(config, TRACE_PREFIX);
        writeJsonFileAtomic(CONFIG_PATH, config);
        return {
          text: `trace: ON (prefix set to ${JSON.stringify(TRACE_PREFIX)}). If the next reply doesn't show it, run /restart once.`,
        };
      }

      const restore = state.previousTelegramPrefix ?? '';
      setTelegramPrefix(config, restore);
      writeJsonFileAtomic(CONFIG_PATH, config);
      saveState({ previousTelegramPrefix: undefined });
      return {
        text: `trace: OFF (prefix restored to ${JSON.stringify(restore)}). If the next reply still shows a prefix, run /restart once.`,
      };
    },
  });
}
EOF

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
config.plugins = config.plugins || {};
config.plugins.entries = config.plugins.entries || {};
config.plugins.load = config.plugins.load || {};
config.plugins.load.paths = config.plugins.load.paths || [];

// Ensure OpenClaw can discover local extensions written under ~/.openclaw/extensions
if (!config.plugins.load.paths.includes('/root/.openclaw/extensions')) {
    config.plugins.load.paths.push('/root/.openclaw/extensions');
}

// Enable local extensions
config.plugins.entries['trace-model'] = config.plugins.entries['trace-model'] || {};
config.plugins.entries['trace-model'].enabled = true;

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
# AUTH RECONCILIATION (safe auto-heal for provider/profile mismatch)
# ============================================================
AUTH_STORE="/root/.openclaw/agents/main/agent/auth-profiles.json"
OAUTH_STORE="/root/.openclaw/credentials/oauth.json"
AUTH_STATE_FILE="/tmp/openclaw-auth-state.json"
AUTH_DEGRADED_MARKER="/tmp/openclaw-auth-degraded"

# Auth profile restore paths for rclone
R2_AUTH_PREFIX="$RCLONE_REMOTE/openclaw/agents/main/agent"
LEGACY_R2_AUTH_PREFIX="$RCLONE_REMOTE/agents/main/agent"

check_auth_provider_state() {
    node << 'EOFAUTH'
const fs = require('fs');

const configPath = '/root/.openclaw/openclaw.json';
const authPath = '/root/.openclaw/agents/main/agent/auth-profiles.json';
const statePath = '/tmp/openclaw-auth-state.json';

function readJson(path) {
    if (!fs.existsSync(path)) return null;
    try {
        return JSON.parse(fs.readFileSync(path, 'utf8'));
    } catch {
        return null;
    }
}

function getPrimaryModel(config) {
    if (!config || typeof config !== 'object') return null;
    const model = config?.agents?.defaults?.model;
    if (typeof model === 'string') return model;
    if (model && typeof model === 'object' && typeof model.primary === 'string') {
        return model.primary;
    }
    return null;
}

function providerFromModel(modelRef) {
    if (!modelRef || typeof modelRef !== 'string') return null;
    const trimmed = modelRef.trim();
    if (!trimmed || trimmed.startsWith('http://') || trimmed.startsWith('https://')) return null;
    const slashIdx = trimmed.indexOf('/');
    if (slashIdx <= 0) return null;
    return trimmed.substring(0, slashIdx).toLowerCase();
}

function hasProviderEnvKey(provider) {
    const p = String(provider || '').toLowerCase();
    // Mirror OpenClaw's env resolution for the providers we commonly use here.
    if (p === 'anthropic') return !!(process.env.ANTHROPIC_OAUTH_TOKEN || process.env.ANTHROPIC_API_KEY);
    if (p === 'openai') return !!process.env.OPENAI_API_KEY;
    return false;
}

function hasProviderInAuthStore(storeObj, provider) {
    if (!storeObj || !provider) return false;
    const p = String(provider).toLowerCase();

    // Current store format: { version: 1, profiles: { "<id>": { type, provider, ... } } }
    if (storeObj.profiles && typeof storeObj.profiles === 'object') {
        for (const [id, cred] of Object.entries(storeObj.profiles)) {
            if (!cred || typeof cred !== 'object') continue;
            const prov = String(cred.provider || '').toLowerCase();
            if (prov === p) return true;
            if (String(id).toLowerCase().startsWith(p + ':')) return true;
        }
        return false;
    }

    // Legacy store (plain object map). Be conservative but avoid false negatives.
    for (const [id, cred] of Object.entries(storeObj)) {
        if (!cred || typeof cred !== 'object') continue;
        const prov = String(cred.provider || '').toLowerCase();
        if (prov === p) return true;
        if (String(id).toLowerCase().startsWith(p + ':')) return true;
    }
    return false;
}

const config = readJson(configPath);
const primaryModel = getPrimaryModel(config);
const primaryProvider = providerFromModel(primaryModel);

let authRaw = '';
let authObj = null;
if (fs.existsSync(authPath)) {
    try {
        authRaw = fs.readFileSync(authPath, 'utf8');
        authObj = JSON.parse(authRaw);
    } catch {
        authRaw = '';
        authObj = null;
    }
}

const authProfilesPresent = authRaw.trim().length > 0;
const hasRequiredProvider = primaryProvider
    ? (hasProviderEnvKey(primaryProvider) || hasProviderInAuthStore(authObj, primaryProvider))
    : true;
const mismatch = !!primaryProvider && !hasRequiredProvider;

const state = {
    primaryModel: primaryModel,
    primaryProvider: primaryProvider,
    authProfilesPresent: authProfilesPresent,
    hasRequiredProvider: hasRequiredProvider,
    mismatch: mismatch,
};

try {
    fs.writeFileSync(statePath, JSON.stringify(state, null, 2));
} catch {}

console.log(
    '[AUTH-RECONCILE] primary_model=' + (primaryModel || 'none') +
    ' primary_provider=' + (primaryProvider || 'none') +
    ' auth_profiles_present=' + authProfilesPresent +
    ' has_required_provider=' + hasRequiredProvider
);

process.exit(mismatch ? 42 : 0);
EOFAUTH
}

AUTH_RECONCILE_REQUIRED=false
if check_auth_provider_state; then
    echo "[AUTH-RECONCILE] Provider/auth profile state is consistent"
else
    AUTH_CHECK_STATUS=$?
    if [ "$AUTH_CHECK_STATUS" -eq 42 ]; then
        AUTH_RECONCILE_REQUIRED=true
        echo "[AUTH-RECONCILE] Provider/auth profile mismatch detected"
    else
        echo "[AUTH-RECONCILE] WARNING: Unable to verify provider/auth profile state (exit $AUTH_CHECK_STATUS)"
    fi
fi

if [ "$DO_RESTORE" = true ] && [ "$AUTH_RECONCILE_REQUIRED" = true ]; then
    echo "[AUTH-RECONCILE] Restore integrity warning: config restored but provider profile missing"
fi

if [ "$AUTH_RECONCILE_REQUIRED" = true ] && [ "$RCLONE_AVAILABLE" = true ]; then
    # Try to restore auth profiles from R2 via rclone
    if rclone ls "$R2_AUTH_PREFIX/auth-profiles.json" &>/dev/null; then
        echo "[AUTH-RECONCILE] Restoring auth profiles from R2 backup"
        mkdir -p "$(dirname "$AUTH_STORE")"
        rclone copy "$R2_AUTH_PREFIX/auth-profiles.json" "$(dirname "$AUTH_STORE")/" --fast-list
    elif rclone ls "$LEGACY_R2_AUTH_PREFIX/auth-profiles.json" &>/dev/null; then
        echo "[AUTH-RECONCILE] Restoring auth profiles from legacy R2 backup path"
        mkdir -p "$(dirname "$AUTH_STORE")"
        rclone copy "$LEGACY_R2_AUTH_PREFIX/auth-profiles.json" "$(dirname "$AUTH_STORE")/" --fast-list
    else
        echo "[AUTH-RECONCILE] No auth-profiles backup found in R2"
    fi

    if check_auth_provider_state; then
        AUTH_RECONCILE_REQUIRED=false
        echo "[AUTH-RECONCILE] Reconciled provider/auth profile mismatch from backup"
    else
        AUTH_CHECK_STATUS=$?
        if [ "$AUTH_CHECK_STATUS" -ne 42 ]; then
            echo "[AUTH-RECONCILE] WARNING: Post-restore auth state check failed (exit $AUTH_CHECK_STATUS)"
        fi
    fi
fi

if [ -n "${OPENAI_API_KEY:-}" ]; then
    # Ensure Codex fallback can authenticate.
    #
    # OpenClaw does NOT read OPENAI_API_KEY for provider "openai-codex"; it must be present
    # in the per-agent auth store at /root/.openclaw/agents/<agentId>/agent/auth-profiles.json
    # using the modern store shape:
    #   { "version": 1, "profiles": { "openai-codex:default": { "type": "token", "provider": "openai-codex", "token": "...", "expires": <ms> } } }
    #
    # We also opportunistically migrate legacy auth-profiles.json formats that stored
    # `{ apiKey }` at the top-level (not readable by OpenClaw v2026.2.12).
    NEEDS_OPENAI_CODEX=false
    if node -e "const fs=require('fs');const p='/root/.openclaw/openclaw.json';const c=JSON.parse(fs.readFileSync(p,'utf8'));const m=c?.agents?.defaults?.model||{};const refs=[];if(typeof m==='string')refs.push(m);if(m&&typeof m==='object'){if(typeof m.primary==='string')refs.push(m.primary);if(Array.isArray(m.fallbacks))refs.push(...m.fallbacks.filter(x=>typeof x==='string'));} process.exit(refs.some(r=>String(r).startsWith('openai-codex/'))?0:1)"; then
        NEEDS_OPENAI_CODEX=true
    fi

    if [ "$NEEDS_OPENAI_CODEX" = true ]; then
        node << 'EOFCODEX'
const fs = require('fs');
const path = require('path');

const AUTH_PATH = '/root/.openclaw/agents/main/agent/auth-profiles.json';
const provider = 'openai-codex';
const envToken = String(process.env.OPENAI_API_KEY || '').trim();

function isJwt(t) {
  return /^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(t);
}

function decodeJwtPayload(t) {
  const parts = t.split('.');
  if (parts.length !== 3) return null;
  const b64 = parts[1].replace(/-/g, '+').replace(/_/g, '/');
  const pad = b64 + '='.repeat((4 - (b64.length % 4)) % 4);
  try {
    return JSON.parse(Buffer.from(pad, 'base64').toString('utf8'));
  } catch {
    return null;
  }
}

function loadJson(p) {
  try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch { return null; }
}

function writeJson(p, value) {
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, JSON.stringify(value, null, 2));
}

function ensureStoreShape(raw) {
  if (raw && typeof raw === 'object' && raw.profiles && typeof raw.profiles === 'object') {
    return {
      version: Number(raw.version || 1) || 1,
      profiles: raw.profiles,
      order: raw.order,
      lastGood: raw.lastGood,
      usageStats: raw.usageStats,
    };
  }
  return { version: 1, profiles: {} };
}

function migrateLegacyIntoStore(raw) {
  // Legacy map: { "<id>": { provider, apiKey } }
  if (!raw || typeof raw !== 'object' || raw.profiles) return null;
  const out = { version: 1, profiles: {} };
  for (const [id, cred] of Object.entries(raw)) {
    if (!cred || typeof cred !== 'object') continue;
    const providerId = String(cred.provider || String(id).split(':')[0] || '').trim();
    if (!providerId) continue;
    const apiKey = String(cred.apiKey || cred.key || cred.token || '').trim();
    if (!apiKey) continue;
    const profileId = `${providerId}:default`;
    if (providerId === 'openai-codex') {
      const payload = isJwt(apiKey) ? (decodeJwtPayload(apiKey) || {}) : {};
      const expSeconds = typeof payload.exp === 'number' ? payload.exp : null;
      const expires = expSeconds ? expSeconds * 1000 : undefined;
      out.profiles[profileId] = { type: 'token', provider: providerId, token: apiKey, ...(expires ? { expires } : {}) };
    } else {
      out.profiles[profileId] = { type: 'api_key', provider: providerId, key: apiKey };
    }
  }
  return Object.keys(out.profiles).length ? out : null;
}

function findProfileIds(store, providerId) {
  const pref = String(providerId).toLowerCase() + ':';
  return Object.keys(store.profiles || {}).filter((id) => String(id).toLowerCase().startsWith(pref));
}

function isExpired(cred) {
  if (!cred || typeof cred !== 'object') return false;
  if (typeof cred.expires !== 'number' || !Number.isFinite(cred.expires) || cred.expires <= 0) return false;
  return Date.now() >= cred.expires;
}

// 1) Load and migrate legacy auth-profiles.json if needed.
const raw = loadJson(AUTH_PATH);
let store = ensureStoreShape(raw);
const migrated = migrateLegacyIntoStore(raw);
if (migrated) {
  store = ensureStoreShape(migrated);
  writeJson(AUTH_PATH, store);
  console.log('[AUTH-RECONCILE] Migrated legacy auth-profiles.json to modern store format');
}

// 2) Ensure openai-codex token profile exists and is not expired.
const profileIds = findProfileIds(store, provider);
const hasValid = profileIds.some((id) => {
  const cred = store.profiles[id];
  if (!cred) return false;
  if (String(cred.type) !== 'token' && String(cred.type) !== 'oauth') return false;
  if (String(cred.provider || '').toLowerCase() !== provider) return false;
  return !isExpired(cred);
});

if (!hasValid && envToken) {
  if (!isJwt(envToken)) {
    console.log('[AUTH-RECONCILE] OPENAI_API_KEY does not look like an OAuth/JWT token; cannot bootstrap openai-codex');
    process.exit(0);
  }
  const payload = decodeJwtPayload(envToken) || {};
  const expSeconds = typeof payload.exp === 'number' ? payload.exp : null;
  const expires = expSeconds ? expSeconds * 1000 : undefined;
  if (expires && Date.now() >= expires) {
    console.log('[AUTH-RECONCILE] OPENAI_API_KEY OAuth/JWT token is expired; cannot bootstrap openai-codex');
    process.exit(0);
  }

  store.profiles[`${provider}:default`] = {
    type: 'token',
    provider,
    token: envToken,
    ...(expires ? { expires } : {}),
  };
  writeJson(AUTH_PATH, { version: 1, profiles: store.profiles });
  console.log('[AUTH-RECONCILE] Bootstrapped openai-codex auth profile from OPENAI_API_KEY');
}
EOFCODEX
    fi
fi

if [ "$AUTH_RECONCILE_REQUIRED" = true ] && [ -f "$OAUTH_STORE" ]; then
    echo "[AUTH-RECONCILE] OAuth credentials detected, running non-interactive auth refresh"
    openclaw models list --json >/tmp/openclaw-auth-reconcile.log 2>&1 || \
    openclaw doctor --non-interactive >>/tmp/openclaw-auth-reconcile.log 2>&1 || true

    if check_auth_provider_state; then
        AUTH_RECONCILE_REQUIRED=false
        echo "[AUTH-RECONCILE] Reconciled provider/auth profile mismatch after auth refresh"
    else
        AUTH_CHECK_STATUS=$?
        if [ "$AUTH_CHECK_STATUS" -ne 42 ]; then
            echo "[AUTH-RECONCILE] WARNING: Post-refresh auth state check failed (exit $AUTH_CHECK_STATUS)"
        fi
    fi
fi

if [ "$AUTH_RECONCILE_REQUIRED" = true ]; then
    PRIMARY_PROVIDER=$(node -e "const fs=require('fs');try{const s=JSON.parse(fs.readFileSync('$AUTH_STATE_FILE','utf8'));process.stdout.write(s.primaryProvider||'unknown')}catch{process.stdout.write('unknown')}")
    echo "$(date -Iseconds) primary_provider=$PRIMARY_PROVIDER status=degraded" > "$AUTH_DEGRADED_MARKER"
    echo "[AUTH-RECONCILE] ERROR: No auth profile found for provider '$PRIMARY_PROVIDER'. Gateway will start in degraded mode."
    echo "[AUTH-RECONCILE] Resolve via: openclaw agents add main (or restore auth-profiles.json), then restart."
else
    rm -f "$AUTH_DEGRADED_MARKER" 2>/dev/null || true
fi

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
# The bootstrap installs tools (pip3, rclone, uv, amp, etc.) that
# survive only on rootfs. After a cold restart the rootfs is wiped but
# the .bootstrap-complete marker may survive in the R2-backed workspace.
# Use pip3 absence as the definitive canary for fresh rootfs.
# NOTE: python3 is pre-installed in the base image, so it can't be used as canary.
# HAL_STORAGE creds are now available via process env vars from Worker.
if ! command -v pip3 &>/dev/null && [ -f "$WORKSPACE_DIR/.bootstrap.sh" ]; then
    echo "Fresh rootfs detected (pip3 missing). Running bootstrap in background..."
    bash "$WORKSPACE_DIR/.bootstrap.sh" > /tmp/bootstrap.log 2>&1 &
    echo "Bootstrap started (PID: $!), log at /tmp/bootstrap.log"
elif ! command -v pip3 &>/dev/null; then
    echo "WARNING: pip3 missing but no .bootstrap.sh found — first boot?"
else
    echo "Rootfs tools present (pip3 found), skipping bootstrap"
fi

# ============================================================
# BACKGROUND SYNC (replaces Worker-side cron sync)
# ============================================================
if [ "$RCLONE_AVAILABLE" = true ]; then
    (
        sleep 60  # Wait for gateway to stabilize
        echo "[sync] Background sync started"
        while true; do
            # Determine config dir
            if [ -f /root/.openclaw/openclaw.json ]; then
                SYNC_CONFIG="/root/.openclaw"
            elif [ -f /root/.clawdbot/clawdbot.json ]; then
                SYNC_CONFIG="/root/.clawdbot"
            else
                sleep 30; continue
            fi

            rclone sync "$SYNC_CONFIG/" "$RCLONE_REMOTE/openclaw/" \
                --transfers=8 --fast-list --s3-no-check-bucket \
                --exclude '.git/**' --exclude '*.lock' --exclude '*.log' --exclude '*.tmp' 2>/dev/null || true

            [ -d /root/clawd ] && rclone sync /root/clawd/ "$RCLONE_REMOTE/workspace/" \
                --transfers=8 --fast-list --s3-no-check-bucket \
                --exclude 'skills/**' --exclude '.git/**' 2>/dev/null || true

            [ -d /root/clawd/skills ] && rclone sync /root/clawd/skills/ "$RCLONE_REMOTE/skills/" \
                --transfers=8 --fast-list --s3-no-check-bucket 2>/dev/null || true

            date -Iseconds | rclone rcat "$RCLONE_REMOTE/.last-sync" 2>/dev/null || true

            sleep 30
        done
    ) &
    echo "Background sync loop started (PID: $!)"
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
