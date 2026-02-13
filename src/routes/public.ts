import { Hono } from 'hono';
import type { AppEnv } from '../types';
import { MOLTBOT_PORT } from '../config';
import { ensureMoltbotGateway, findExistingMoltbotProcess, probeGatewayHttp, waitForProcess } from '../gateway';

/**
 * Public routes - NO Cloudflare Access authentication required
 *
 * These routes are mounted BEFORE the auth middleware is applied.
 * Includes: health checks, static assets, and public API endpoints.
 */
const publicRoutes = new Hono<AppEnv>();

// GET /sandbox-health - Health check endpoint
publicRoutes.get('/sandbox-health', (c) => {
  return c.json({
    status: 'ok',
    service: 'moltbot-sandbox',
    gateway_port: MOLTBOT_PORT,
  });
});

// GET /logo.png - Serve logo from ASSETS binding
publicRoutes.get('/logo.png', (c) => {
  return c.env.ASSETS.fetch(c.req.raw);
});

// GET /logo-small.png - Serve small logo from ASSETS binding
publicRoutes.get('/logo-small.png', (c) => {
  return c.env.ASSETS.fetch(c.req.raw);
});

// GET /api/status - Public health check for gateway status (no auth required)
publicRoutes.get('/api/status', async (c) => {
  const sandbox = c.get('sandbox');

  try {
    const process = await findExistingMoltbotProcess(sandbox);
    const reachable = await probeGatewayHttp(sandbox, 1500);

    if (reachable) {
      return c.json({ ok: true, status: 'running', processId: process?.id || 'untracked' });
    }

    if (!process) return c.json({ ok: false, status: 'not_running' });
    return c.json({ ok: false, status: 'not_responding', processId: process.id });
  } catch (err) {
    return c.json({
      ok: false,
      status: 'error',
      error: err instanceof Error ? err.message : 'Unknown error',
    });
  }
});

// GET /_admin/assets/* - Admin UI static assets (CSS, JS need to load for login redirect)
// Assets are built to dist/client with base "/_admin/"
publicRoutes.get('/_admin/assets/*', async (c) => {
  const url = new URL(c.req.url);
  // Rewrite /_admin/assets/* to /assets/* for the ASSETS binding
  const assetPath = url.pathname.replace('/_admin/assets/', '/assets/');
  const assetUrl = new URL(assetPath, url.origin);
  return c.env.ASSETS.fetch(new Request(assetUrl.toString(), c.req.raw));
});

// POST /api/start - Start the gateway (public endpoint for HAL)
publicRoutes.post('/api/start', async (c) => {
  const sandbox = c.get('sandbox');

  try {
    console.log('[API/START] Starting gateway...');
    await ensureMoltbotGateway(sandbox, c.env);
    console.log('[API/START] Gateway started successfully');

    const process = await findExistingMoltbotProcess(sandbox);
    return c.json({
      ok: true,
      status: 'running',
      processId: process?.id || 'untracked'
    });
  } catch (err) {
    console.error('[API/START] Failed to start gateway:', err);
    return c.json({
      ok: false,
      error: err instanceof Error ? err.message : 'Unknown error'
    }, 500);
  }
});

// POST /api/force-restart - Kill all processes and restart gateway (emergency cleanup)
publicRoutes.post('/api/force-restart', async (c) => {
  const sandbox = c.get('sandbox');

  try {
    const processes = await sandbox.listProcesses();
    console.log(`[FORCE-RESTART] Killing ${processes.length} processes`);

    for (const proc of processes) {
      try {
        await proc.kill();
      } catch {
        // Ignore kill errors
      }
    }

    // Sandbox kill() doesn't always reap spawned gateway children; best-effort cleanup.
    // Use `timeout` so this never leaves behind a long-running "cleanup" process.
    try {
      const proc = await sandbox.startProcess(
        "bash -lc 'if command -v pkill >/dev/null 2>&1; then timeout 2 pkill -f \"[o]penclaw-gateway\" || true; timeout 2 pkill -f \"[/]usr/local/bin/start-openclaw.sh\" || true; timeout 2 pkill -x openclaw || true; fi; true'",
      );
      await waitForProcess(proc, 5000);
      if (proc.status === 'running' || proc.status === 'starting') {
        try {
          await proc.kill();
        } catch {
          // ignore
        }
      }
    } catch {
      // ignore
    }

    return c.json({
      ok: true,
      killed: processes.length,
      message: 'All processes killed. Gateway will restart on next request.'
    });
  } catch (err) {
    return c.json({
      ok: false,
      error: err instanceof Error ? err.message : 'Unknown error'
    }, 500);
  }
});

export { publicRoutes };
