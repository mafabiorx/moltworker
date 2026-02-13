import fs from 'node:fs';
import path from 'node:path';

type CommandCtx = {
  // OpenClaw passes args as a string (everything after the command), but keep
  // array support for compatibility with older SDKs.
  args?: string | string[];
};

const CONFIG_PATH = '/root/.openclaw/openclaw.json';
const STATE_PATH = '/root/.openclaw/trace-model.state.json';

const TRACE_PREFIX = '[{model}] ';

function readJsonFile(p: string): any {
  const raw = fs.readFileSync(p, 'utf8');
  return JSON.parse(raw);
}

function writeJsonFileAtomic(p: string, value: any): void {
  const dir = path.dirname(p);
  fs.mkdirSync(dir, { recursive: true });
  const tmp = `${p}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(value, null, 2) + '\n', 'utf8');
  fs.renameSync(tmp, p);
}

function getTelegramPrefix(config: any): string {
  return String(config?.channels?.telegram?.responsePrefix || '');
}

function setTelegramPrefix(config: any, prefix: string): void {
  config.channels = config.channels || {};
  config.channels.telegram = config.channels.telegram || {};
  config.channels.telegram.responsePrefix = prefix;
}

function loadState(): { previousTelegramPrefix?: string } {
  try {
    return readJsonFile(STATE_PATH) || {};
  } catch {
    return {};
  }
}

function saveState(state: { previousTelegramPrefix?: string }): void {
  writeJsonFileAtomic(STATE_PATH, state);
}

function normalizeArg(arg: string | undefined): 'on' | 'off' | 'status' {
  const a = (arg || '').trim().toLowerCase();
  if (a === 'on') return 'on';
  if (a === 'off') return 'off';
  return 'status';
}

function firstWord(args: CommandCtx['args']): string | undefined {
  if (Array.isArray(args)) return args[0];
  if (typeof args === 'string') return args.trim().split(/\s+/)[0];
  return undefined;
}

export default function traceModelPlugin(api: any) {
  api.registerCommand({
    name: 'trace',
    description: 'Toggle Telegram model prefix tracing. Usage: /trace on|off|status',
    acceptsArgs: true,
    requireAuth: true,
    handler: async (ctx: CommandCtx) => {
      let config: any;
      try {
        config = readJsonFile(CONFIG_PATH);
      } catch (err) {
        return {
          text: `trace: failed to read config at ${CONFIG_PATH}: ${
            err instanceof Error ? err.message : String(err)
          }`,
        };
      }

      const state = loadState();
      const action = normalizeArg(firstWord(ctx.args));
      const currentPrefix = getTelegramPrefix(config);

      if (action === 'status') {
        const enabled = currentPrefix.trim().length > 0;
        return {
          text: `trace: ${enabled ? 'ON' : 'OFF'} (telegram responsePrefix=${JSON.stringify(
            currentPrefix,
          )}). Use: /trace on|off`,
        };
      }

      if (action === 'on') {
        // Preserve the existing prefix so we can restore it.
        if (state.previousTelegramPrefix === undefined) {
          state.previousTelegramPrefix = currentPrefix;
          saveState(state);
        }
        setTelegramPrefix(config, TRACE_PREFIX);
        writeJsonFileAtomic(CONFIG_PATH, config);
        return {
          text: `trace: ON (prefix set to ${JSON.stringify(
            TRACE_PREFIX,
          )}). If the next reply doesn't show it, run /restart once.`,
        };
      }

      // off
      const restore = state.previousTelegramPrefix ?? '';
      setTelegramPrefix(config, restore);
      writeJsonFileAtomic(CONFIG_PATH, config);
      saveState({ previousTelegramPrefix: undefined });
      return {
        text: `trace: OFF (prefix restored to ${JSON.stringify(
          restore,
        )}). If the next reply still shows a prefix, run /restart once.`,
      };
    },
  });
}
