import { Hono } from 'hono';
import { describe, expect, it, vi } from 'vitest';
import type { Sandbox, Process } from '@cloudflare/sandbox';
import type { AppEnv } from '../types';
import { createMockEnv } from '../test-utils';
import { debug } from './debug';

function createCompletedProcess(stdout: string = '', stderr: string = ''): Process {
  return {
    id: 'proc-1',
    command: 'cat',
    status: 'completed',
    startTime: new Date(),
    endTime: new Date(),
    exitCode: 0,
    waitForPort: vi.fn(),
    waitForLog: vi.fn(),
    waitForExit: vi.fn(),
    getStatus: vi.fn().mockResolvedValue('completed'),
    kill: vi.fn(),
    getLogs: vi.fn().mockResolvedValue({ stdout, stderr }),
  } as unknown as Process;
}

describe('debug auth-state route', () => {
  it('returns sanitized auth/provider summary', async () => {
    const sandbox = {
      startProcess: vi.fn().mockImplementation(async (cmd: string) => {
        if (cmd.includes('/root/.openclaw/openclaw.json')) {
          return createCompletedProcess(
            JSON.stringify({
              agents: { defaults: { model: { primary: 'openai-codex/gpt-5.3-codex' } } },
            }),
          );
        }
        if (cmd.includes('/root/.openclaw/agents/main/agent/auth-profiles.json')) {
          return createCompletedProcess(
            JSON.stringify({
              profiles: [{ provider: 'openai-codex', apiKey: 'sk-test-secret' }],
            }),
          );
        }
        if (cmd.includes('/root/.openclaw/credentials/oauth.json')) {
          return createCompletedProcess('exists\n');
        }
        return createCompletedProcess('');
      }),
    } as unknown as Sandbox;

    const app = new Hono<AppEnv>();
    app.use('*', async (c, next) => {
      c.set('sandbox', sandbox);
      await next();
    });
    app.route('/debug', debug);

    const env = createMockEnv({ DEBUG_ROUTES: 'true' });
    const res = await app.request('http://example.test/debug/auth-state', {}, env);
    const body = await res.json();

    expect(res.status).toBe(200);
    expect(body).toEqual({
      primary_model: 'openai-codex/gpt-5.3-codex',
      primary_provider: 'openai-codex',
      agent_id: 'main',
      auth_profiles_present: true,
      providers_with_profiles: ['openai-codex'],
      has_legacy_oauth_import_file: true,
      mismatch_detected: false,
    });
    expect(JSON.stringify(body)).not.toContain('sk-test-secret');
  });
});
