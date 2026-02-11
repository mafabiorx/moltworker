# Switch to New Claude Max Account

## Context
User has a new Claude Max subscription and wants to update the HAL worker to use it.

## How Claude Max Auth Works
OpenClaw uses `claude setup-token` (from Claude Code CLI) to generate an authentication token for Claude Max subscriptions. This token replaces the standard `ANTHROPIC_API_KEY`.

## Steps

### 1. Update Secret in Wrangler
```bash
cd /home/fabio/projects/Moltbot-HAL
echo "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" | npx wrangler secret put ANTHROPIC_API_KEY
```

### 2. Redeploy (optional but recommended)
```bash
npm run deploy
```

### 3. Restart Gateway
```bash
curl -X POST https://hal.mafabiorx68.workers.dev/api/start
```
(Requires Cloudflare Access auth)

## Verification
- Test via Control UI: `https://hal.mafabiorx68.workers.dev/?token=YOUR_GATEWAY_TOKEN`
- Or check health: `/_admin/` dashboard

## Notes
- Claude Max usage may be subject to Anthropic's ToS for automated access
- The setup-token expires and may need periodic renewal
