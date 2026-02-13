import type { MoltbotEnv } from '../types';

/**
 * Build environment variables to pass to the OpenClaw container process
 *
 * @param env - Worker environment bindings
 * @returns Environment variables record
 */
export function buildEnvVars(env: MoltbotEnv): Record<string, string> {
  const envVars: Record<string, string> = {};

  // Cloudflare AI Gateway configuration (new native provider)
  if (env.CLOUDFLARE_AI_GATEWAY_API_KEY) {
    envVars.CLOUDFLARE_AI_GATEWAY_API_KEY = env.CLOUDFLARE_AI_GATEWAY_API_KEY;
  }
  if (env.CF_AI_GATEWAY_ACCOUNT_ID) {
    envVars.CF_AI_GATEWAY_ACCOUNT_ID = env.CF_AI_GATEWAY_ACCOUNT_ID;
  }
  if (env.CF_AI_GATEWAY_GATEWAY_ID) {
    envVars.CF_AI_GATEWAY_GATEWAY_ID = env.CF_AI_GATEWAY_GATEWAY_ID;
  }

  // Direct provider keys
  if (env.ANTHROPIC_API_KEY) envVars.ANTHROPIC_API_KEY = env.ANTHROPIC_API_KEY;
  if (env.OPENAI_API_KEY) envVars.OPENAI_API_KEY = env.OPENAI_API_KEY;

  // Legacy AI Gateway support: AI_GATEWAY_BASE_URL + AI_GATEWAY_API_KEY
  // When set, these override direct keys for backward compatibility
  if (env.AI_GATEWAY_API_KEY && env.AI_GATEWAY_BASE_URL) {
    const normalizedBaseUrl = env.AI_GATEWAY_BASE_URL.replace(/\/+$/, '');
    envVars.AI_GATEWAY_BASE_URL = normalizedBaseUrl;
    // Legacy path routes through Anthropic base URL
    envVars.ANTHROPIC_BASE_URL = normalizedBaseUrl;
    envVars.ANTHROPIC_API_KEY = env.AI_GATEWAY_API_KEY;
  } else if (env.ANTHROPIC_BASE_URL) {
    envVars.ANTHROPIC_BASE_URL = env.ANTHROPIC_BASE_URL;
  }

  // Map MOLTBOT_GATEWAY_TOKEN to OPENCLAW_GATEWAY_TOKEN (container expects this name)
  if (env.MOLTBOT_GATEWAY_TOKEN) envVars.OPENCLAW_GATEWAY_TOKEN = env.MOLTBOT_GATEWAY_TOKEN;
  if (env.DEV_MODE) envVars.OPENCLAW_DEV_MODE = env.DEV_MODE;
  if (env.TELEGRAM_BOT_TOKEN) envVars.TELEGRAM_BOT_TOKEN = env.TELEGRAM_BOT_TOKEN;
  if (env.TELEGRAM_DM_POLICY) envVars.TELEGRAM_DM_POLICY = env.TELEGRAM_DM_POLICY;
  if (env.DISCORD_BOT_TOKEN) envVars.DISCORD_BOT_TOKEN = env.DISCORD_BOT_TOKEN;
  if (env.DISCORD_DM_POLICY) envVars.DISCORD_DM_POLICY = env.DISCORD_DM_POLICY;
  if (env.SLACK_BOT_TOKEN) envVars.SLACK_BOT_TOKEN = env.SLACK_BOT_TOKEN;
  if (env.SLACK_APP_TOKEN) envVars.SLACK_APP_TOKEN = env.SLACK_APP_TOKEN;
  if (env.CF_AI_GATEWAY_MODEL) envVars.CF_AI_GATEWAY_MODEL = env.CF_AI_GATEWAY_MODEL;
  if (env.CF_ACCOUNT_ID) envVars.CF_ACCOUNT_ID = env.CF_ACCOUNT_ID;
  if (env.CDP_SECRET) envVars.CDP_SECRET = env.CDP_SECRET;
  if (env.WORKER_URL) envVars.WORKER_URL = env.WORKER_URL;

  // GitHub PAT for workspace git sync (bootstrap needs it)
  if (env.GH_PAT) envVars.GH_PAT = env.GH_PAT;

  // R2 credentials for rclone restore/sync (passed per-process, always fresh)
  if (env.R2_ACCESS_KEY_ID) envVars.R2_ACCESS_KEY_ID = env.R2_ACCESS_KEY_ID;
  if (env.R2_SECRET_ACCESS_KEY) envVars.R2_SECRET_ACCESS_KEY = env.R2_SECRET_ACCESS_KEY;
  if (env.R2_BUCKET_NAME) envVars.R2_BUCKET_NAME = env.R2_BUCKET_NAME;
  if (env.CF_ACCOUNT_ID) envVars.CF_ACCOUNT_ID = env.CF_ACCOUNT_ID;

  // HAL_STORAGE credentials for bootstrap binary cache
  if (env.HAL_STORAGE_ACCESS_KEY) envVars.HAL_STORAGE_ACCESS_KEY = env.HAL_STORAGE_ACCESS_KEY;
  if (env.HAL_STORAGE_SECRET_KEY) envVars.HAL_STORAGE_SECRET_KEY = env.HAL_STORAGE_SECRET_KEY;
  if (env.HAL_STORAGE_ENDPOINT) envVars.HAL_STORAGE_ENDPOINT = env.HAL_STORAGE_ENDPOINT;

  return envVars;
}
