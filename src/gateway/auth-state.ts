interface AuthStateInput {
  configText: string | null;
  authProfilesText: string | null;
  oauthFilePresent?: boolean;
  agentId?: string;
}

export interface AuthStateSummary {
  primary_model: string | null;
  primary_provider: string | null;
  agent_id: string;
  auth_profiles_present: boolean;
  providers_with_profiles: string[];
  has_legacy_oauth_import_file: boolean;
  mismatch_detected: boolean;
}

const MODEL_PROVIDER_RE = /^([a-z0-9][a-z0-9._-]*)\/([^\s]+)$/i;
const SIMPLE_PROVIDER_RE = /^[a-z0-9][a-z0-9._-]*$/i;

function parseJson(text: string | null): unknown {
  if (!text || !text.trim()) return null;
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

function getPrimaryModelFromConfig(config: unknown): string | null {
  if (!config || typeof config !== 'object') return null;
  const record = config as Record<string, unknown>;
  const agents = record.agents as Record<string, unknown> | undefined;
  const defaults = agents?.defaults as Record<string, unknown> | undefined;
  const model = defaults?.model as Record<string, unknown> | string | undefined;
  if (typeof model === 'string') return model;
  if (model && typeof model === 'object' && typeof model.primary === 'string') {
    return model.primary;
  }
  return null;
}

function providerFromModelRef(modelRef: string | null): string | null {
  if (!modelRef) return null;
  const trimmed = modelRef.trim();
  if (!trimmed || trimmed.startsWith('http://') || trimmed.startsWith('https://')) return null;
  const match = trimmed.match(MODEL_PROVIDER_RE);
  if (!match) return null;
  return match[1];
}

function addProvider(set: Set<string>, maybeProvider: string | null): void {
  if (!maybeProvider) return;
  const normalized = maybeProvider.trim().toLowerCase();
  if (!normalized || !SIMPLE_PROVIDER_RE.test(normalized)) return;
  set.add(normalized);
}

function collectProviders(
  value: unknown,
  out: Set<string>,
  parentKey = '',
  seen = new WeakSet<object>(),
): void {
  if (typeof value === 'string') {
    if (parentKey === 'provider' || parentKey === 'providername' || parentKey === 'providerid') {
      addProvider(out, value);
    }
    addProvider(out, providerFromModelRef(value));
    return;
  }

  if (!value || typeof value !== 'object') return;
  if (seen.has(value as object)) return;
  seen.add(value as object);

  if (Array.isArray(value)) {
    for (const item of value) {
      collectProviders(item, out, parentKey, seen);
    }
    return;
  }

  const record = value as Record<string, unknown>;
  for (const [key, child] of Object.entries(record)) {
    addProvider(out, providerFromModelRef(key));
    collectProviders(child, out, key.toLowerCase(), seen);
  }
}

function hasProviderToken(raw: string | null, provider: string | null): boolean {
  if (!raw || !provider) return false;
  const escaped = provider.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const tokenBoundaryRe = new RegExp(`(^|[^a-z0-9._-])${escaped}([^a-z0-9._-]|$)`, 'i');
  return tokenBoundaryRe.test(raw);
}

export function summarizeAuthState(input: AuthStateInput): AuthStateSummary {
  const configObj = parseJson(input.configText);
  const authProfilesObj = parseJson(input.authProfilesText);

  const primaryModel = getPrimaryModelFromConfig(configObj);
  const primaryProvider = providerFromModelRef(primaryModel);
  const authProfilesPresent = !!input.authProfilesText?.trim();

  const providers = new Set<string>();
  collectProviders(authProfilesObj, providers);

  if (primaryProvider && hasProviderToken(input.authProfilesText, primaryProvider)) {
    providers.add(primaryProvider);
  }

  const providersWithProfiles = Array.from(providers);
  const hasPrimaryProviderProfile = primaryProvider
    ? providersWithProfiles.includes(primaryProvider)
    : true;

  return {
    primary_model: primaryModel,
    primary_provider: primaryProvider,
    agent_id: input.agentId || 'main',
    auth_profiles_present: authProfilesPresent,
    providers_with_profiles: providersWithProfiles,
    has_legacy_oauth_import_file: !!input.oauthFilePresent,
    mismatch_detected: !!primaryProvider && !hasPrimaryProviderProfile,
  };
}
