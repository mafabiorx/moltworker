/**
 * Shared test utilities for mocking sandbox and environment
 */
import { vi } from 'vitest';
import type { Sandbox, Process } from '@cloudflare/sandbox';
import type { MoltbotEnv } from './types';

/**
 * Create a minimal MoltbotEnv object for testing
 */
export function createMockEnv(overrides: Partial<MoltbotEnv> = {}): MoltbotEnv {
  return {
    Sandbox: {} as any,
    ASSETS: {} as any,
    MOLTBOT_BUCKET: {} as any,
    HAL_STORAGE: {} as any,
    ...overrides,
  };
}

/**
 * Create a mock env with R2 credentials configured
 */
export function createMockEnvWithR2(overrides: Partial<MoltbotEnv> = {}): MoltbotEnv {
  return createMockEnv({
    R2_ACCESS_KEY_ID: 'test-key-id',
    R2_SECRET_ACCESS_KEY: 'test-secret-key',
    CF_ACCOUNT_ID: 'test-account-id',
    ...overrides,
  });
}

/**
 * Create a mock process object
 */
export function createMockProcess(
  stdout: string = '',
  options: { exitCode?: number; stderr?: string; status?: string } = {},
): Partial<Process> {
  const { exitCode = 0, stderr = '', status = 'completed' } = options;
  return {
    status: status as Process['status'],
    exitCode,
    getLogs: vi.fn().mockResolvedValue({ stdout, stderr }),
  };
}

/**
 * Create a mock ExecResult for sandbox.exec() calls
 */
export function createMockExecResult(
  stdout: string = '',
  options: { success?: boolean; stderr?: string; exitCode?: number } = {},
) {
  const { success = true, stderr = '', exitCode = 0 } = options;
  return { stdout, stderr, success, exitCode };
}

export interface MockSandbox {
  sandbox: Sandbox;
  execMock: ReturnType<typeof vi.fn>;
  startProcessMock: ReturnType<typeof vi.fn>;
  listProcessesMock: ReturnType<typeof vi.fn>;
  containerFetchMock: ReturnType<typeof vi.fn>;
}

/**
 * Create a mock sandbox with configurable behavior
 */
export function createMockSandbox(
  options: {
    processes?: Partial<Process>[];
  } = {},
): MockSandbox {
  const listProcessesMock = vi.fn().mockResolvedValue(options.processes || []);
  const containerFetchMock = vi.fn();

  // Default exec mock returns success
  const execMock = vi.fn().mockImplementation(async (cmd: string) => {
    const s = String(cmd);

    // Config detection for syncToR2
    if (s.includes('test -f /root/.openclaw/openclaw.json')) {
      return createMockExecResult('openclaw');
    }

    // Default success
    return createMockExecResult('');
  });

  // Command-aware default for startProcess (still used by debug routes, api routes)
  const startProcessMock = vi.fn().mockImplementation(async () => {
    return createMockProcess('');
  });

  const sandbox = {
    exec: execMock,
    listProcesses: listProcessesMock,
    startProcess: startProcessMock,
    containerFetch: containerFetchMock,
    wsConnect: vi.fn(),
  } as unknown as Sandbox;

  return { sandbox, execMock, startProcessMock, listProcessesMock, containerFetchMock };
}

/**
 * Suppress console output during tests
 */
export function suppressConsole() {
  vi.spyOn(console, 'log').mockImplementation(() => {});
  vi.spyOn(console, 'error').mockImplementation(() => {});
  vi.spyOn(console, 'warn').mockImplementation(() => {});
}
