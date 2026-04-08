# Provider Profile Design

## Goal

Add first-class third-party provider profile switching to `codex-auth` while preserving existing ChatGPT account switching.

The smallest viable design is:

- keep ChatGPT account switching centered on `~/.codex/auth.json`
- add a separate provider-profile object model centered on `~/.codex/config.toml`
- present both kinds of targets through the existing `list`, `switch`, and `remove` flows

This avoids forcing provider configuration into the current ChatGPT account identity model.

## Context

Current `codex-auth` behavior is built around ChatGPT auth snapshots:

- `login`, `import`, and `purge` manage ChatGPT auth files
- switching a ChatGPT account copies a managed snapshot into `~/.codex/auth.json`
- usage refresh, team-name refresh, and auto-switch depend on ChatGPT tokens and account IDs

Current Codex behavior already supports custom model providers through `~/.codex/config.toml`, including provider selection and provider-specific endpoint/auth settings. Because of that, third-party provider switching should update Codex config instead of pretending to be a ChatGPT auth snapshot.

## Approaches Considered

### Approach A: Dual model with unified switch surface

Store ChatGPT accounts and provider profiles as different target kinds in the registry, but render them together in `list`, `switch`, and `remove`.

Pros:

- matches Codex's actual split between `auth.json` and `config.toml`
- minimizes risk to existing ChatGPT refresh and auto-switch paths
- keeps one user-facing switch surface

Cons:

- requires a small registry schema expansion
- requires merged rendering and matching logic

### Approach B: Treat provider profiles as fake accounts

Insert provider profiles into the existing account list using synthetic identity fields.

Pros:

- superficially smaller data-model change

Cons:

- corrupts account semantics
- forces provider-specific exceptions into usage refresh, team-name refresh, purge, import, and auto-switch
- makes long-term maintenance worse

### Approach C: Separate provider commands and separate switch flow

Add a provider-only switch flow and leave existing account commands unchanged.

Pros:

- lower implementation risk than a unified view

Cons:

- does not satisfy the requirement that provider profiles coexist with ChatGPT accounts in the same switch experience

## Recommendation

Use Approach A.

It is the smallest design that preserves current ChatGPT behavior, aligns with Codex's native configuration model, and still gives one unified switch surface.

## Scope

### In scope

- provider profiles stored by `codex-auth`
- unified `list`, `switch`, and `remove` across ChatGPT accounts and provider profiles
- provider-profile activation by rewriting `~/.codex/config.toml`
- ChatGPT account activation continuing to rewrite `~/.codex/auth.json`
- explicit status output for active provider profile vs active ChatGPT account

### Out of scope for the first version

- provider-profile usage refresh
- provider-profile team/account metadata refresh
- provider-profile auto-switch
- import/purge/login flows for provider profiles
- encrypted secret storage

## Data Model

Extend the registry with a second top-level collection:

```toml
provider_profiles = [
  {
    profile_id = "openrouter",
    label = "openrouter",
    provider_id = "openrouter",
    base_url = "https://openrouter.ai/api/v1",
    api_key = "sk-...",
    wire_api = "responses",
    model = "openai/gpt-5",
    created_at = 0,
    last_used_at = 0,
  },
]
```

Add a unified active target representation:

- `active_target_kind = "account" | "provider_profile"`
- `active_target_id = <account_key or profile_id>`

Compatibility rules:

- existing registries without provider data load with an empty provider-profile list
- existing `active_account_key` data is migrated to `active_target_kind = "account"` and `active_target_id = active_account_key`
- ChatGPT account records keep their current structure unchanged

## Activation Semantics

### Switch to ChatGPT account

- keep the current auth snapshot replacement flow
- set the active target to that account
- restore Codex provider selection to the default OpenAI/ChatGPT path by clearing or normalizing provider-related overrides that would force a third-party provider

### Switch to provider profile

- do not depend on `~/.codex/auth.json`
- set the active target to the selected provider profile
- rewrite `~/.codex/config.toml` so Codex uses:
  - `model_provider = "<provider_id>"`
  - `model_providers.<provider_id>.base_url = "<base_url>"`
  - `model_providers.<provider_id>.api_key = "<api_key>"`
  - `model_providers.<provider_id>.wire_api = "responses"`
  - optional model binding when configured

`auth.json` is left untouched when switching to a provider profile.

## CLI Design

### New provider-management commands

- `codex-auth provider add <label> --base-url <url> --api-key <key> [--provider-id <id>] [--model <model>]`
- `codex-auth provider list`
- `codex-auth provider update <query> [--label <label>] [--base-url <url>] [--api-key <key>] [--provider-id <id>] [--model <model>]`
- `codex-auth provider remove <query>`

### Unified everyday commands

- `codex-auth list` shows both ChatGPT accounts and provider profiles
- `codex-auth switch [<query>]` matches both ChatGPT accounts and provider profiles
- `codex-auth remove [<query>]` removes either kind

Display guidance:

- provider profiles should render with an explicit type marker such as `provider`
- query matching should include provider label and provider ID
- mixed results must remain unambiguous during interactive selection

## Status and Refresh Behavior

When the active target is a ChatGPT account:

- preserve current status, usage refresh, and API refresh behavior

When the active target is a provider profile:

- status should report `auth: provider`
- status should show the active provider profile label or provider ID
- usage should render as `n/a` or `unsupported`
- ChatGPT usage refresh and team-name refresh should be skipped

## Auto-Switch Rules

First version behavior:

- auto-switch remains ChatGPT-account-only
- provider profiles are excluded from auto-switch candidate selection
- if the active target is a provider profile, the daemon should not try to score or rotate provider profiles

This keeps the initial implementation small and avoids inventing unsupported usage semantics for arbitrary providers.

## Config Rewrite Rules

Provider-profile activation must preserve unrelated user config.

Required behavior:

- read the existing `~/.codex/config.toml`
- update only the keys needed for provider selection
- preserve unrelated project, plugin, UI, sandbox, and profile settings
- write `wire_api = "responses"` for managed provider profiles

ChatGPT-account activation should similarly avoid destroying unrelated config and should only clear provider overrides that would prevent returning to the normal OpenAI/ChatGPT path.

## Security and Storage

First version stores provider API keys in plain text inside `~/.codex/config.toml` and in `registry.json`.

This is accepted for the minimal design because:

- it matches the chosen user preference
- it avoids adding encryption, OS keychain integration, or environment-file orchestration to the first version

The user-facing help and docs must state this clearly.

## Testing

Add coverage for:

- loading old registries without provider profiles
- migrating active-account state into unified active-target state
- adding, updating, listing, switching, and removing provider profiles
- merged list rendering with both ChatGPT accounts and provider profiles
- query matching across both target kinds
- switching from ChatGPT account to provider profile
- switching from provider profile back to ChatGPT account
- preserving unrelated `config.toml` fields during provider activation
- skipping ChatGPT usage refresh paths when the active target is a provider profile

## Implementation Order

1. Extend registry schema and migration logic for provider profiles and unified active target.
2. Add provider CRUD commands.
3. Add config read/write helpers for managed provider activation.
4. Merge `list`, `switch`, and `remove` target selection across both kinds.
5. Update `status` and refresh paths to branch on active target kind.
6. Add tests for migration, switching, and config preservation.

## Risks

- careless config rewriting could delete unrelated user settings
- mixed list rendering could make target selection ambiguous
- existing code that assumes the active target is always a ChatGPT account may need explicit guards

## Decision Summary

The first version should add provider profiles as a separate target kind, unify the switch surface, keep ChatGPT account logic intact, and treat provider activation as a `config.toml` rewrite instead of an `auth.json` swap.
