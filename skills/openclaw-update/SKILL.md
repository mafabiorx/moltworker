---
name: openclaw-update
description: "Safely check for and plan OpenClaw updates in Dockerfile-based deployments. Audits versions, checks compatibility, and outputs the exact changes needed — but NEVER modifies the running system."
allowed-tools: [Read, exec, web_search, web_fetch, gateway]
---

# OpenClaw Update Skill

## Overview

This skill manages OpenClaw version updates for **Dockerfile-based container deployments** where:
- The Dockerfile pins `openclaw@X.Y.Z`
- `start-moltbot.sh` rebuilds config from env vars on each boot
- R2 syncs the runtime config
- npm updates at runtime are **ephemeral** (lost on container restart)

## ⛔ CRITICAL SAFETY RULES

1. **NEVER run `npm i -g openclaw@latest` or `gateway update.run` at runtime.** Runtime npm updates are ephemeral in Dockerfile-based deployments. The container will revert to the Dockerfile-pinned version on next restart, causing model/config mismatches and potential lockout.

2. **NEVER modify config to reference models the RUNNING version doesn't support.** If the running version is 2026.2.2-3 and you add `anthropic/claude-opus-4-6` as primary (which requires 2026.2.6+), the next restart will lock out the agent entirely. Config changes and version updates are a **two-phase commit** — version first, config second.

3. **NEVER remove a custom provider block unless the running version has native support for all models it defined.** Custom providers (like `cloudflare-ai-gateway`) may be workarounds for missing catalog entries. Removing them before the catalog catches up = lockout.

4. **The two-phase commit rule:**
   - **Phase 1**: Update the Dockerfile, redeploy, confirm new version is running
   - **Phase 2**: ONLY THEN modify config to use new models/features
   - Never combine both phases. Never assume Phase 1 succeeded without verification.

5. **Always preserve a working fallback model in the config.** The `agents.defaults.model.fallbacks` array must contain at least one model that exists in the CURRENT running version's built-in catalog (e.g., `anthropic/claude-sonnet-4-5` is safe across most versions).

## Decision Tree

```
User asks about updating OpenClaw
│
├─ Step 1: AUDIT (safe, read-only)
│   ├─ Get running version: openclaw --version
│   ├─ Get latest version: npm view openclaw version
│   ├─ Get latest stable: npm view openclaw dist-tags --json
│   ├─ Compare versions
│   └─ If already latest → STOP, report "up to date"
│
├─ Step 2: CHANGELOG REVIEW
│   ├─ Fetch changelog between current and latest
│   │   URL: https://raw.githubusercontent.com/openclaw/openclaw/refs/heads/main/CHANGELOG.md
│   ├─ Identify: breaking changes, new model support, security fixes
│   ├─ Identify: new features relevant to our setup
│   └─ Summarize changes for the operator
│
├─ Step 3: COMPATIBILITY CHECK
│   ├─ Parse current config (gateway config.get)
│   ├─ List all model references in config:
│   │   - agents.defaults.model.primary
│   │   - agents.defaults.model.fallbacks[]
│   │   - agents.defaults.models{} keys
│   │   - agents.defaults.subagents.model
│   │   - Any per-agent overrides
│   ├─ Check if any referenced models are ONLY available in newer version
│   ├─ Check if any custom provider blocks could be removed after update
│   ├─ Check for deprecated config keys in changelog
│   └─ Flag any risks
│
├─ Step 4: GENERATE UPDATE PLAN (output only, never execute)
│   ├─ Dockerfile change:
│   │   FROM: RUN npm i -g openclaw@<current>
│   │   TO:   RUN npm i -g openclaw@<target>
│   ├─ If config changes are safe post-update:
│   │   List exact config.patch JSON to apply AFTER redeploy
│   ├─ If custom providers can be removed:
│   │   List which ones and why (only after confirming new catalog)
│   ├─ Deploy command:
│   │   wrangler deploy (or docker build + push, depending on setup)
│   └─ Post-deploy verification steps
│
└─ Step 5: POST-UPDATE VERIFICATION (after operator redeploys)
    ├─ Confirm version: openclaw --version
    ├─ Confirm model availability: check built-in catalog
    ├─ Run: openclaw doctor --non-interactive
    ├─ Test model resolution: send a test message
    ├─ ONLY NOW apply config changes (Phase 2)
    └─ Verify config changes took effect
```

## Audit Commands Reference

```bash
# Running version
openclaw --version

# Latest available
npm view openclaw version
npm view openclaw dist-tags --json

# Current config (via gateway tool)
gateway config.get

# Health check
openclaw doctor --non-interactive

# Check if a model is in the built-in catalog
# (grep the dist bundle — fragile but useful)
grep -l "claude-opus-4-6" /usr/local/lib/node_modules/openclaw/dist/*.js
```

## Our Deployment Architecture

```
┌─────────────────────────────────────┐
│  Cloudflare Worker (Dockerfile)     │
│  ┌───────────────────────────────┐  │
│  │ FROM node:22                  │  │
│  │ RUN npm i -g openclaw@X.Y.Z  │◄─── Version pinned HERE
│  │ COPY start-moltbot.sh .      │  │
│  │ CMD ["./start-moltbot.sh"]   │  │
│  └───────────────────────────────┘  │
│                                     │
│  start-moltbot.sh:                  │
│  1. Rebuilds openclaw.json from     │
│     environment variables           │
│  2. Populates model allowlist       │◄─── Model refs must match
│  3. Starts openclaw gateway         │     the pinned version
│  └──────────────────────────────    │
│                                     │
│  R2 Bucket (/data/moltbot/):        │
│  - Syncs runtime config/sessions    │
│  - Skills persistence               │
│  - OAuth credentials                │
└─────────────────────────────────────┘
```

**Key implication**: `npm i -g` at runtime updates the binary but the Dockerfile still has the old version. On next container restart (sleep/wake, deploy, crash), the old version comes back. Any config that references features/models from the new version will break.

## Update Plan Template

When generating an update plan, use this format:

```markdown
## OpenClaw Update Plan: X.Y.Z → A.B.C

### Changes Summary
- [list key changes from changelog]

### Risk Assessment
- Model compatibility: ✅/⚠️/❌
- Config compatibility: ✅/⚠️/❌
- Breaking changes: ✅ none / ⚠️ list them

### Required Changes

**1. Dockerfile** (in Moltbot-HAL repo):
```dockerfile
# Line N: change
RUN npm i -g openclaw@A.B.C
```

**2. start-moltbot.sh** (if model allowlist needs updating):
```bash
# Add/remove model entries as needed
```

**3. Deploy**:
```bash
cd /home/fabio/projects/Moltbot-HAL
wrangler deploy
```

**4. Post-deploy verification**:
- [ ] `openclaw --version` returns A.B.C
- [ ] `openclaw doctor --non-interactive` passes
- [ ] Test message sends successfully
- [ ] Telegram channel responds

**5. Config changes** (ONLY after verification):
```json
// config.patch to apply via gateway tool
```
```

## What This Skill Does NOT Do

- ❌ Run `npm i -g openclaw@latest` in the container
- ❌ Run `gateway update.run`
- ❌ Modify `agents.defaults.model.primary` to a model not in the running catalog
- ❌ Remove custom provider blocks without confirming native support
- ❌ Combine version update + config change in one step
- ❌ Assume a runtime npm update will persist

## Incident Reference: The 2026-02-07 Lockout

**What happened**: HAL updated openclaw via `gateway update.run` (runtime npm update) from 2026.2.2-3 to 2026.2.6-3, then removed the custom `cloudflare-ai-gateway` provider and set `anthropic/claude-opus-4-6` as primary. On container restart, the Dockerfile rebuilt with 2026.2.2-3 (which doesn't know opus-4-6). Result: total lockout — couldn't respond, compact, or switch models.

**Root cause**: Runtime npm update + config change in one step. The config assumed a version that didn't persist.

**Fix**: Claude Code updated Dockerfile to pin 2026.2.6-3, fixed start-moltbot.sh to populate full model allowlist, redeployed.

**Lesson**: This skill exists so this never happens again.
