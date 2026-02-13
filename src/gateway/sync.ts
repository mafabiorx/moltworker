import type { Sandbox } from '@cloudflare/sandbox';
import type { MoltbotEnv } from '../types';
import { getR2BucketName } from '../config';

export interface SyncResult {
  success: boolean;
  lastSync?: string;
  error?: string;
  details?: string;
}

/**
 * Generate rclone config command.
 * Credentials are passed via env vars to avoid embedding secrets in command strings.
 */
function rcloneConfigCmd(): string {
  // Use single quotes around heredoc delimiter to prevent JS template literal issues.
  // Shell variable expansion ($VAR) still works because the heredoc itself is unquoted.
  const dollar = '$';
  return `mkdir -p /root/.config/rclone && cat > /root/.config/rclone/rclone.conf << EOF
[r2]
type = s3
provider = Cloudflare
access_key_id = ${dollar}R2_ACCESS_KEY_ID
secret_access_key = ${dollar}R2_SECRET_ACCESS_KEY
endpoint = https://${dollar}CF_ACCOUNT_ID.r2.cloudflarestorage.com
acl = private
EOF`;
}

/**
 * Sync OpenClaw config and workspace from container to R2 for persistence.
 *
 * Uses rclone direct S3 API access instead of s3fs FUSE mount + rsync.
 * Credentials are passed per-exec via env vars.
 *
 * Syncs up to three directories:
 * - Config: /root/.openclaw/ (or /root/.clawdbot/) → R2:/openclaw/
 * - Workspace: /root/clawd/ → R2:/workspace/ (if exists)
 * - Skills: /root/clawd/skills/ → R2:/skills/ (if exists)
 */
export async function syncToR2(sandbox: Sandbox, env: MoltbotEnv): Promise<SyncResult> {
  if (!env.R2_ACCESS_KEY_ID || !env.R2_SECRET_ACCESS_KEY || !env.CF_ACCOUNT_ID) {
    return { success: false, error: 'R2 storage is not configured' };
  }

  const bucket = getR2BucketName(env);
  const remote = `r2:${bucket}`;
  const rcloneEnv = {
    R2_ACCESS_KEY_ID: env.R2_ACCESS_KEY_ID,
    R2_SECRET_ACCESS_KEY: env.R2_SECRET_ACCESS_KEY,
    CF_ACCOUNT_ID: env.CF_ACCOUNT_ID,
  };

  // Ensure rclone config exists
  const configResult = await sandbox.exec(rcloneConfigCmd(), { env: rcloneEnv });
  if (!configResult.success) {
    return { success: false, error: 'Failed to create rclone config', details: configResult.stderr };
  }

  // Detect config dir
  const check = await sandbox.exec(
    'test -f /root/.openclaw/openclaw.json && echo openclaw || (test -f /root/.clawdbot/clawdbot.json && echo clawdbot || echo none)',
  );
  const configType = check.stdout.trim();
  if (configType === 'none') {
    return {
      success: false,
      error: 'Sync aborted: no config file found',
      details: 'Neither openclaw.json nor clawdbot.json found in config directory.',
    };
  }
  const configDir = configType === 'openclaw' ? '/root/.openclaw' : '/root/.clawdbot';

  // Sync config
  const excludes = "--exclude '.git/**' --exclude '*.lock' --exclude '*.log' --exclude '*.tmp'";
  const configSync = await sandbox.exec(
    `rclone sync ${configDir}/ ${remote}/openclaw/ --transfers=8 --fast-list --s3-no-check-bucket ${excludes}`,
    { timeout: 120_000 },
  );
  if (!configSync.success) {
    return { success: false, error: 'Config sync failed', details: configSync.stderr };
  }

  // Sync workspace (excluding skills and .git)
  await sandbox.exec(
    `[ -d /root/clawd ] && rclone sync /root/clawd/ ${remote}/workspace/ --transfers=8 --fast-list --s3-no-check-bucket --exclude 'skills/**' --exclude '.git/**' || true`,
    { timeout: 120_000 },
  );

  // Sync skills
  await sandbox.exec(
    `[ -d /root/clawd/skills ] && rclone sync /root/clawd/skills/ ${remote}/skills/ --transfers=8 --fast-list --s3-no-check-bucket || true`,
    { timeout: 120_000 },
  );

  // Write timestamp
  await sandbox.exec(`date -Iseconds | rclone rcat ${remote}/.last-sync`);

  return { success: true, lastSync: new Date().toISOString() };
}
