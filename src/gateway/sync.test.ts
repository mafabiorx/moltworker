import { describe, it, expect, beforeEach } from 'vitest';
import { syncToR2 } from './sync';
import {
  createMockEnv,
  createMockEnvWithR2,
  createMockExecResult,
  createMockSandbox,
  suppressConsole,
} from '../test-utils';

describe('syncToR2', () => {
  beforeEach(() => {
    suppressConsole();
  });

  describe('configuration checks', () => {
    it('returns error when R2 is not configured', async () => {
      const { sandbox } = createMockSandbox();
      const env = createMockEnv();

      const result = await syncToR2(sandbox, env);

      expect(result.success).toBe(false);
      expect(result.error).toBe('R2 storage is not configured');
    });

    it('returns error when rclone config creation fails', async () => {
      const { sandbox, execMock } = createMockSandbox();
      execMock.mockImplementation(async (cmd: string) => {
        if (String(cmd).includes('rclone.conf')) {
          return createMockExecResult('', { success: false, stderr: 'permission denied' });
        }
        return createMockExecResult('');
      });

      const env = createMockEnvWithR2();
      const result = await syncToR2(sandbox, env);

      expect(result.success).toBe(false);
      expect(result.error).toBe('Failed to create rclone config');
    });
  });

  describe('sanity checks', () => {
    it('returns error when source has no config file', async () => {
      const { sandbox, execMock } = createMockSandbox();
      execMock.mockImplementation(async (cmd: string) => {
        const s = String(cmd);
        if (s.includes('rclone.conf')) return createMockExecResult('');
        if (s.includes('test -f /root/.openclaw/openclaw.json')) {
          return createMockExecResult('none');
        }
        return createMockExecResult('');
      });

      const env = createMockEnvWithR2();
      const result = await syncToR2(sandbox, env);

      expect(result.success).toBe(false);
      expect(result.error).toBe('Sync aborted: no config file found');
    });
  });

  describe('sync execution', () => {
    it('returns success when all rclone commands succeed', async () => {
      const { sandbox, execMock } = createMockSandbox();
      execMock.mockImplementation(async (cmd: string) => {
        const s = String(cmd);
        if (s.includes('rclone.conf')) return createMockExecResult('');
        if (s.includes('test -f /root/.openclaw/openclaw.json')) {
          return createMockExecResult('openclaw');
        }
        if (s.includes('rclone sync')) return createMockExecResult('');
        if (s.includes('rclone rcat')) return createMockExecResult('');
        return createMockExecResult('');
      });

      const env = createMockEnvWithR2();
      const result = await syncToR2(sandbox, env);

      expect(result.success).toBe(true);
      expect(result.lastSync).toBeTruthy();
    });

    it('falls back to legacy clawdbot config directory', async () => {
      const { sandbox, execMock } = createMockSandbox();
      execMock.mockImplementation(async (cmd: string) => {
        const s = String(cmd);
        if (s.includes('rclone.conf')) return createMockExecResult('');
        if (s.includes('test -f /root/.openclaw/openclaw.json')) {
          return createMockExecResult('clawdbot');
        }
        return createMockExecResult('');
      });

      const env = createMockEnvWithR2();
      const result = await syncToR2(sandbox, env);

      expect(result.success).toBe(true);

      // rclone sync should reference .clawdbot
      const syncCall = execMock.mock.calls.find(
        (c: unknown[]) => String(c[0]).includes('rclone sync') && String(c[0]).includes('.clawdbot'),
      );
      expect(syncCall).toBeTruthy();
    });

    it('returns error when config sync fails', async () => {
      const { sandbox, execMock } = createMockSandbox();
      execMock.mockImplementation(async (cmd: string) => {
        const s = String(cmd);
        if (s.includes('rclone.conf')) return createMockExecResult('');
        if (s.includes('test -f /root/.openclaw/openclaw.json')) {
          return createMockExecResult('openclaw');
        }
        if (s.includes('rclone sync') && s.includes('openclaw/')) {
          return createMockExecResult('', { success: false, stderr: 'sync error' });
        }
        return createMockExecResult('');
      });

      const env = createMockEnvWithR2();
      const result = await syncToR2(sandbox, env);

      expect(result.success).toBe(false);
      expect(result.error).toBe('Config sync failed');
    });

    it('passes R2 credentials via exec env for rclone config', async () => {
      const { sandbox, execMock } = createMockSandbox();

      const env = createMockEnvWithR2();
      await syncToR2(sandbox, env);

      // First call should be rclone config with env vars
      const configCall = execMock.mock.calls.find(
        (c: unknown[]) => String(c[0]).includes('rclone.conf'),
      );
      expect(configCall).toBeTruthy();
      expect(configCall![1]).toEqual(
        expect.objectContaining({
          env: {
            R2_ACCESS_KEY_ID: 'test-key-id',
            R2_SECRET_ACCESS_KEY: 'test-secret-key',
            CF_ACCOUNT_ID: 'test-account-id',
          },
        }),
      );
    });

    it('uses custom bucket name from R2_BUCKET_NAME env var', async () => {
      const { sandbox, execMock } = createMockSandbox();

      const env = createMockEnvWithR2({ R2_BUCKET_NAME: 'custom-bucket' });
      await syncToR2(sandbox, env);

      // Sync calls should use custom bucket name
      const syncCall = execMock.mock.calls.find(
        (c: unknown[]) => String(c[0]).includes('r2:custom-bucket'),
      );
      expect(syncCall).toBeTruthy();
    });

    it('verifies rclone sync command excludes .git', async () => {
      const { sandbox, execMock } = createMockSandbox();

      const env = createMockEnvWithR2();
      await syncToR2(sandbox, env);

      const syncCall = execMock.mock.calls.find(
        (c: unknown[]) => String(c[0]).includes('rclone sync') && String(c[0]).includes('openclaw/'),
      );
      expect(syncCall).toBeTruthy();
      expect(String(syncCall![0])).toContain(".git/**");
      expect(String(syncCall![0])).toContain('/root/.openclaw/');
    });
  });
});
