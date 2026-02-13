import { describe, expect, it } from 'vitest';
import { summarizeAuthState } from './auth-state';

describe('summarizeAuthState', () => {
  it('detects mismatch when primary provider has no auth profile', () => {
    const result = summarizeAuthState({
      configText: JSON.stringify({
        agents: { defaults: { model: { primary: 'openai-codex/gpt-5.3-codex' } } },
      }),
      authProfilesText: JSON.stringify({
        profiles: [{ provider: 'anthropic', name: 'default' }],
      }),
      oauthFilePresent: true,
    });

    expect(result.primary_model).toBe('openai-codex/gpt-5.3-codex');
    expect(result.primary_provider).toBe('openai-codex');
    expect(result.providers_with_profiles).toEqual(['anthropic']);
    expect(result.mismatch_detected).toBe(true);
  });

  it('passes when auth profile provider matches primary provider', () => {
    const result = summarizeAuthState({
      configText: JSON.stringify({
        agents: { defaults: { model: { primary: 'openai-codex/gpt-5.3-codex' } } },
      }),
      authProfilesText: JSON.stringify({
        profiles: [{ provider: 'openai-codex', name: 'oauth' }],
      }),
    });

    expect(result.providers_with_profiles).toEqual(['openai-codex']);
    expect(result.mismatch_detected).toBe(false);
  });

  it('extracts providers from model references in auth profile blobs', () => {
    const result = summarizeAuthState({
      configText: JSON.stringify({
        agents: { defaults: { model: { primary: 'anthropic/claude-sonnet-4-5' } } },
      }),
      authProfilesText: JSON.stringify({
        entries: [{ model: 'openai-codex/gpt-5.3-codex' }, { model: 'anthropic/claude-opus-4-6' }],
      }),
    });

    expect(result.providers_with_profiles).toEqual(['openai-codex', 'anthropic']);
    expect(result.mismatch_detected).toBe(false);
  });

  it('is resilient when auth-profiles JSON is malformed', () => {
    const result = summarizeAuthState({
      configText: JSON.stringify({
        agents: { defaults: { model: { primary: 'openai-codex/gpt-5.3-codex' } } },
      }),
      authProfilesText: '{"profiles":[{"provider":"openai-codex"',
    });

    expect(result.auth_profiles_present).toBe(true);
    expect(result.providers_with_profiles).toEqual(['openai-codex']);
    expect(result.mismatch_detected).toBe(false);
  });

  it('returns a sanitized response shape without secrets', () => {
    const secret = 'sk-test-super-secret';
    const result = summarizeAuthState({
      configText: JSON.stringify({
        agents: { defaults: { model: { primary: 'openai-codex/gpt-5.3-codex' } } },
      }),
      authProfilesText: JSON.stringify({
        profiles: [{ provider: 'openai-codex', apiKey: secret }],
      }),
      oauthFilePresent: true,
      agentId: 'main',
    });

    expect(result).toEqual({
      primary_model: 'openai-codex/gpt-5.3-codex',
      primary_provider: 'openai-codex',
      agent_id: 'main',
      auth_profiles_present: true,
      providers_with_profiles: ['openai-codex'],
      has_legacy_oauth_import_file: true,
      mismatch_detected: false,
    });
    expect(JSON.stringify(result)).not.toContain(secret);
  });
});
