# Provider Profile Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add managed third-party provider profiles to `codex-auth`, let them coexist with ChatGPT accounts in unified `list`, `switch`, and `remove`, and activate them by rewriting `~/.codex/config.toml`.

**Architecture:** Keep ChatGPT account switching on the existing `auth.json` snapshot path and add a parallel provider-profile path driven by `config.toml`. Persist provider profiles in `registry.json`, introduce a unified active-target state, and add a small managed block writer for `config.toml` instead of a full TOML parser. Render both target kinds through shared target-row builders while keeping usage refresh and auto-switch account-only.

**Tech Stack:** Zig 0.15.1, Zig stdlib JSON APIs, existing CLI/registry/test harness, controlled text rewrite for `config.toml`

---

## File Structure

### Existing files to modify

- `src/registry.zig`
  - Extend on-disk schema and in-memory registry state with provider profiles and unified active target fields.
  - Add provider-profile CRUD helpers and active-target helpers.
- `src/main.zig`
  - Add provider subcommand handlers.
  - Merge provider targets into `list`, `switch`, and `remove`.
  - Branch auth/config activation logic by target kind.
- `src/cli.zig`
  - Parse `provider add|list|update|remove`.
  - Extend help text and provider management output.
  - Update interactive switch/remove rendering to show target kind.
- `src/format.zig`
  - Print unified account/provider rows for `list`.
- `src/auto.zig`
  - Show provider-aware status.
  - Skip account-only refresh paths when the active target is a provider profile.
- `src/display_rows.zig`
  - Keep account-specific grouping logic, but stop treating it as the only selectable source.
- `src/main.zig`
  - Import new test modules at the bottom of the file.
- `README.md`
  - Document provider-profile commands and behavior.
- `docs/implement.md`
  - Document the new registry/config split and managed `config.toml` block behavior.

### New files to create

- `src/provider_config.zig`
  - Read/write the codex-auth-managed provider block inside `~/.codex/config.toml`.
  - Activate a provider profile and clear provider overrides when switching back to ChatGPT.
- `src/target_rows.zig`
  - Build a unified list of display/switch/remove rows for both accounts and provider profiles.
- `src/tests/provider_config_test.zig`
  - Unit tests for managed block insertion, replacement, and clearing.
- `src/tests/provider_profiles_test.zig`
  - Unit tests for registry migration, provider CRUD, and active-target helpers.
- `src/tests/target_rows_test.zig`
  - Unit tests for mixed account/provider rendering and matching.

### Existing test files likely to modify

- `src/tests/cli_bdd_test.zig`
  - Parser/help coverage for provider commands.
- `src/tests/main_test.zig`
  - Switch/remove/status behavior at handler level.
- `src/tests/e2e_cli_test.zig`
  - End-to-end provider add/switch/remove flows with isolated homes.

## Implementation Assumptions Locked In

- Provider activation is implemented by a codex-auth-managed block in `~/.codex/config.toml`, not by parsing arbitrary TOML.
- The managed block owns only these keys:
  - `model_provider`
  - one `[model_providers.<provider_id>]` table with `base_url`, `api_key`, `wire_api`, and optional `model`
- Removing the active provider profile falls back in this order:
  1. best remaining ChatGPT account by current usage score
  2. first remaining provider profile in sorted order
  3. no active target, with the managed provider block removed from `config.toml`
- Provider profiles never participate in usage refresh, team-name refresh, or auto-switch in this version.

### Task 1: Extend Registry Schema For Provider Profiles

**Files:**
- Modify: `src/registry.zig`
- Modify: `src/main.zig`
- Create: `src/tests/provider_profiles_test.zig`
- Test: `src/tests/registry_test.zig`

- [ ] **Step 1: Write the failing registry migration and provider CRUD tests**

```zig
test "Scenario: Given legacy active_account_key when loading then active_target migrates to account" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("accounts");
    try tmp.dir.writeFile(.{
        .sub_path = "accounts/registry.json",
        .data =
            \\{
            \\  "schema_version": 3,
            \\  "active_account_key": "user-1::acct-1",
            \\  "active_account_activated_at_ms": 123,
            \\  "auto_switch": {"enabled": false, "threshold_5h_percent": 10, "threshold_weekly_percent": 5},
            \\  "api": {"usage": true, "account": true, "list_refresh_all": false},
            \\  "accounts": []
            \\}
        ,
    });

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);

    var reg = try registry.loadRegistry(gpa, codex_home);
    defer reg.deinit(gpa);

    try std.testing.expectEqual(registry.ActiveTargetKind.account, reg.active_target_kind.?);
    try std.testing.expectEqualStrings("user-1::acct-1", reg.active_target_id.?);
}

test "Scenario: Given provider profile when saving and loading then registry preserves it" {
    var reg = registry.Registry{
        .schema_version = registry.current_schema_version,
        .active_account_key = null,
        .active_account_activated_at_ms = null,
        .active_target_kind = .provider_profile,
        .active_target_id = try gpa.dupe(u8, "openrouter"),
        .auto_switch = registry.defaultAutoSwitchConfig(),
        .api = registry.defaultApiConfig(),
        .accounts = std.ArrayList(registry.AccountRecord).empty,
        .provider_profiles = std.ArrayList(registry.ProviderProfile).empty,
    };
    defer reg.deinit(gpa);

    try reg.provider_profiles.append(gpa, .{
        .profile_id = try gpa.dupe(u8, "openrouter"),
        .label = try gpa.dupe(u8, "openrouter"),
        .provider_id = try gpa.dupe(u8, "openrouter"),
        .base_url = try gpa.dupe(u8, "https://openrouter.ai/api/v1"),
        .api_key = try gpa.dupe(u8, "sk-test"),
        .wire_api = try gpa.dupe(u8, "responses"),
        .model = null,
        .created_at = 1,
        .last_used_at = null,
    });
}
```

- [ ] **Step 2: Run the focused registry tests and confirm they fail**

Run:

```bash
mkdir -p /tmp/codex-auth-provider-profile
env HOME=/tmp/codex-auth-provider-profile zig test src/main.zig -lc --test-filter "provider profile"
```

Expected: FAIL with missing `ProviderProfile`, `ActiveTargetKind`, or missing registry fields/helpers.

- [ ] **Step 3: Add provider-profile and active-target state to the registry**

Implement these new types and fields in `src/registry.zig`:

```zig
pub const ActiveTargetKind = enum {
    account,
    provider_profile,
};

pub const ProviderProfile = struct {
    profile_id: []u8,
    label: []u8,
    provider_id: []u8,
    base_url: []u8,
    api_key: []u8,
    wire_api: []u8,
    model: ?[]u8,
    created_at: i64,
    last_used_at: ?i64,
};

pub const Registry = struct {
    schema_version: u32,
    active_account_key: ?[]u8,
    active_account_activated_at_ms: ?i64,
    active_target_kind: ?ActiveTargetKind,
    active_target_id: ?[]u8,
    auto_switch: AutoSwitchConfig,
    api: ApiConfig,
    accounts: std.ArrayList(AccountRecord),
    provider_profiles: std.ArrayList(ProviderProfile),
};
```

Also add these helpers:

```zig
pub fn activeAccountKey(reg: *const Registry) ?[]const u8 {
    if (reg.active_target_kind != .account) return null;
    return reg.active_target_id;
}

pub fn activeProviderProfileId(reg: *const Registry) ?[]const u8 {
    if (reg.active_target_kind != .provider_profile) return null;
    return reg.active_target_id;
}

pub fn setActiveProviderProfile(allocator: std.mem.Allocator, reg: *Registry, profile_id: []const u8) !void {
    if (reg.active_target_id) |value| allocator.free(value);
    reg.active_target_kind = .provider_profile;
    reg.active_target_id = try allocator.dupe(u8, profile_id);
}
```

- [ ] **Step 4: Add migration, parsing, save/load, and CRUD helpers**

Update registry serialization and migration so old registries still load:

```zig
if (root_obj.get("active_target_kind")) |value| {
    reg.active_target_kind = parseActiveTargetKind(value);
}
if (root_obj.get("active_target_id")) |value| {
    reg.active_target_id = try allocator.dupe(u8, readString(value) orelse return error.InvalidRegistry);
} else if (reg.active_account_key) |key| {
    reg.active_target_kind = .account;
    reg.active_target_id = try allocator.dupe(u8, key);
}

if (root_obj.get("provider_profiles")) |profiles_val| switch (profiles_val) {
    .array => |arr| for (arr.items) |item| {
        try reg.provider_profiles.append(allocator, try parseProviderProfile(allocator, item.object));
    },
    else => return error.InvalidRegistry,
}
```

Add sorted CRUD helpers:

```zig
pub fn findProviderProfileIndexById(reg: *const Registry, profile_id: []const u8) ?usize { ... }
pub fn upsertProviderProfile(allocator: std.mem.Allocator, reg: *Registry, profile: ProviderProfile) !void { ... }
pub fn removeProviderProfileById(allocator: std.mem.Allocator, reg: *Registry, profile_id: []const u8) bool { ... }
pub fn firstProviderProfileId(reg: *const Registry) ?[]const u8 { ... }
```

- [ ] **Step 5: Re-run registry tests and commit the schema foundation**

Run:

```bash
env HOME=/tmp/codex-auth-provider-profile zig test src/main.zig -lc --test-filter "provider profile"
```

Expected: PASS for new provider-profile migration/CRUD tests.

Commit:

```bash
git add src/registry.zig src/main.zig src/tests/provider_profiles_test.zig
git commit -m "feat: add provider profile registry state"
```

### Task 2: Add Managed `config.toml` Provider Block Rewriting

**Files:**
- Create: `src/provider_config.zig`
- Modify: `src/main.zig`
- Create: `src/tests/provider_config_test.zig`
- Test: `src/tests/main_test.zig`

- [ ] **Step 1: Write failing tests for config block insertion, replacement, and clearing**

```zig
test "Scenario: Given config without managed block when activating provider then managed block is appended" {
    const before =
        \\model = "gpt-5.4"
        \\
        \\[plugins."github@openai-curated"]
        \\enabled = true
    ;

    const after = try provider_config.renderManagedProviderConfig(
        gpa,
        before,
        .{
            .provider_id = "openrouter",
            .base_url = "https://openrouter.ai/api/v1",
            .api_key = "sk-test",
            .wire_api = "responses",
            .model = null,
        },
    );
    defer gpa.free(after);

    try std.testing.expect(std.mem.indexOf(u8, after, "# BEGIN codex-auth managed provider") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "model_provider = \"openrouter\"") != null);
}

test "Scenario: Given config with managed block when clearing provider then block is removed and unrelated config is preserved" {
    const before =
        \\model = "gpt-5.4"
        \\# BEGIN codex-auth managed provider
        \\model_provider = "openrouter"
        \\
        \\[model_providers.openrouter]
        \\base_url = "https://openrouter.ai/api/v1"
        \\api_key = "sk-test"
        \\wire_api = "responses"
        \\# END codex-auth managed provider
        \\
        \\[tui]
        \\show_tooltips = true
    ;
}
```

- [ ] **Step 2: Run the provider-config tests and confirm they fail**

Run:

```bash
env HOME=/tmp/codex-auth-provider-profile zig test src/main.zig -lc --test-filter "managed block"
```

Expected: FAIL with missing `provider_config` module or missing render helpers.

- [ ] **Step 3: Implement a managed block renderer instead of a full TOML parser**

Create `src/provider_config.zig` with a single managed block format:

```zig
pub const managed_begin = "# BEGIN codex-auth managed provider";
pub const managed_end = "# END codex-auth managed provider";

pub const ManagedProviderConfig = struct {
    provider_id: []const u8,
    base_url: []const u8,
    api_key: []const u8,
    wire_api: []const u8,
    model: ?[]const u8,
};

pub fn renderManagedProviderBlockAlloc(
    allocator: std.mem.Allocator,
    cfg: ManagedProviderConfig,
) ![]u8 {
    return if (cfg.model) |model|
        std.fmt.allocPrint(allocator,
            "{s}\nmodel_provider = \"{s}\"\n\n[model_providers.{s}]\nbase_url = \"{s}\"\napi_key = \"{s}\"\nwire_api = \"{s}\"\nmodel = \"{s}\"\n{s}\n",
            .{ managed_begin, cfg.provider_id, cfg.provider_id, cfg.base_url, cfg.api_key, cfg.wire_api, model, managed_end })
    else
        std.fmt.allocPrint(allocator,
            "{s}\nmodel_provider = \"{s}\"\n\n[model_providers.{s}]\nbase_url = \"{s}\"\napi_key = \"{s}\"\nwire_api = \"{s}\"\n{s}\n",
            .{ managed_begin, cfg.provider_id, cfg.provider_id, cfg.base_url, cfg.api_key, cfg.wire_api, managed_end });
}
```

- [ ] **Step 4: Implement file-level apply/clear helpers and wire them into main**

Add these helpers:

```zig
pub fn applyManagedProviderProfile(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    cfg: ManagedProviderConfig,
) !void { ... }

pub fn clearManagedProviderProfile(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
) !void { ... }

pub fn renderManagedProviderConfig(
    allocator: std.mem.Allocator,
    existing: []const u8,
    cfg: ManagedProviderConfig,
) ![]u8 { ... }
```

Use simple replacement rules:

```zig
const begin_idx = std.mem.indexOf(u8, existing, managed_begin);
const end_idx = std.mem.indexOf(u8, existing, managed_end);
if (begin_idx != null and end_idx != null) {
    // Replace exactly the previous managed block.
} else {
    // Append a blank line plus the new managed block.
}
```

- [ ] **Step 5: Re-run provider-config tests and commit**

Run:

```bash
env HOME=/tmp/codex-auth-provider-profile zig test src/main.zig -lc --test-filter "managed block"
```

Expected: PASS for provider-config unit tests.

Commit:

```bash
git add src/provider_config.zig src/tests/provider_config_test.zig src/main.zig
git commit -m "feat: add managed provider config rewriting"
```

### Task 3: Add Provider CRUD Commands To The CLI

**Files:**
- Modify: `src/cli.zig`
- Modify: `src/main.zig`
- Modify: `src/registry.zig`
- Modify: `src/tests/cli_bdd_test.zig`
- Modify: `src/tests/main_test.zig`

- [ ] **Step 1: Write failing parser and handler tests for provider commands**

```zig
test "Scenario: Given provider add command when parsing then options are captured" {
    const args = [_][:0]const u8{
        "codex-auth", "provider", "add", "openrouter",
        "--base-url", "https://openrouter.ai/api/v1",
        "--api-key", "sk-test",
    };
    const parsed = try cli.parseArgs(gpa, &args);
    defer cli.freeParseResult(gpa, &parsed);

    switch (parsed) {
        .command => |cmd| switch (cmd) {
            .provider => |provider_cmd| switch (provider_cmd) {
                .add => |opts| {
                    try std.testing.expectEqualStrings("openrouter", opts.label);
                    try std.testing.expectEqualStrings("https://openrouter.ai/api/v1", opts.base_url);
                    try std.testing.expectEqualStrings("sk-test", opts.api_key);
                },
                else => return error.TestExpectedEqual,
            },
            else => return error.TestExpectedEqual,
        },
        else => return error.TestExpectedEqual,
    }
}
```

- [ ] **Step 2: Run CLI parser tests and confirm they fail**

Run:

```bash
env HOME=/tmp/codex-auth-provider-profile zig test src/main.zig -lc --test-filter "provider add command"
```

Expected: FAIL with unknown `provider` command or missing provider command union fields.

- [ ] **Step 3: Add provider command parsing and help text**

Extend `src/cli.zig`:

```zig
pub const ProviderAddOptions = struct {
    label: []u8,
    provider_id: ?[]u8,
    base_url: []u8,
    api_key: []u8,
    model: ?[]u8,
};

pub const ProviderCommand = union(enum) {
    add: ProviderAddOptions,
    list: void,
    update: ProviderUpdateOptions,
    remove: ProviderRemoveOptions,
};

pub const Command = union(enum) {
    ...
    provider: ProviderCommand,
};
```

Add top-level parsing:

```zig
if (std.mem.eql(u8, cmd, "provider")) {
    return try parseProviderCommand(allocator, args[2..]);
}
```

- [ ] **Step 4: Add main handlers for provider add/list/update/remove**

Implement handler entry points in `src/main.zig`:

```zig
fn handleProviderAdd(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.ProviderAddOptions) !void { ... }
fn handleProviderList(allocator: std.mem.Allocator, codex_home: []const u8) !void { ... }
fn handleProviderUpdate(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.ProviderUpdateOptions) !void { ... }
fn handleProviderRemove(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.ProviderRemoveOptions) !void { ... }
```

Create provider profiles from CLI options:

```zig
const provider_id = opts.provider_id orelse opts.label;
try registry.upsertProviderProfile(allocator, &reg, .{
    .profile_id = try allocator.dupe(u8, provider_id),
    .label = try allocator.dupe(u8, opts.label),
    .provider_id = try allocator.dupe(u8, provider_id),
    .base_url = try allocator.dupe(u8, opts.base_url),
    .api_key = try allocator.dupe(u8, opts.api_key),
    .wire_api = try allocator.dupe(u8, "responses"),
    .model = if (opts.model) |value| try allocator.dupe(u8, value) else null,
    .created_at = std.time.timestamp(),
    .last_used_at = null,
});
```

- [ ] **Step 5: Re-run provider-command tests and commit**

Run:

```bash
env HOME=/tmp/codex-auth-provider-profile zig test src/main.zig -lc --test-filter "provider"
```

Expected: PASS for parser/help/handler tests involving the new provider commands.

Commit:

```bash
git add src/cli.zig src/main.zig src/registry.zig src/tests/cli_bdd_test.zig src/tests/main_test.zig
git commit -m "feat: add provider profile CLI commands"
```

### Task 4: Unify `list`, `switch`, and `remove` Across Accounts And Provider Profiles

**Files:**
- Create: `src/target_rows.zig`
- Modify: `src/format.zig`
- Modify: `src/cli.zig`
- Modify: `src/main.zig`
- Create: `src/tests/target_rows_test.zig`
- Modify: `src/tests/e2e_cli_test.zig`

- [ ] **Step 1: Write failing mixed-target row and switch tests**

```zig
test "Scenario: Given one account and one provider profile when building target rows then both are selectable" {
    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);

    try appendAccount(gpa, &reg, primary_record_key, "alpha@example.com", "", .pro);
    try reg.provider_profiles.append(gpa, .{
        .profile_id = try gpa.dupe(u8, "openrouter"),
        .label = try gpa.dupe(u8, "openrouter"),
        .provider_id = try gpa.dupe(u8, "openrouter"),
        .base_url = try gpa.dupe(u8, "https://openrouter.ai/api/v1"),
        .api_key = try gpa.dupe(u8, "sk-test"),
        .wire_api = try gpa.dupe(u8, "responses"),
        .model = null,
        .created_at = 1,
        .last_used_at = null,
    });
    try registry.setActiveProviderProfile(gpa, &reg, "openrouter");

    var rows = try target_rows.buildTargetRows(gpa, &reg, null);
    defer rows.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 2), rows.selectable_row_indices.len);
    try std.testing.expect(rows.rows[0].is_active or rows.rows[1].is_active);
}

test "Scenario: Given switch query matching provider label when switching then config is rewritten and active target becomes provider" { ... }
```

- [ ] **Step 2: Run mixed-target tests and confirm they fail**

Run:

```bash
env HOME=/tmp/codex-auth-provider-profile zig test src/main.zig -lc --test-filter "mixed-target"
```

Expected: FAIL with missing `target_rows` module or account-only switch/list logic.

- [ ] **Step 3: Create a unified target-row builder**

Create `src/target_rows.zig`:

```zig
pub const TargetKind = enum {
    account,
    provider_profile,
};

pub const TargetRow = struct {
    kind: TargetKind,
    account_index: ?usize,
    provider_profile_index: ?usize,
    account_cell: []u8,
    plan_cell: []const u8,
    rate_5h_cell: []u8,
    rate_week_cell: []u8,
    last_cell: []u8,
    depth: u8,
    is_active: bool,
    is_header: bool,
};
```

Build rows by:

- reusing current grouped account behavior for ChatGPT accounts
- appending provider profiles as flat rows under a `providers` header when any exist
- marking provider rows with:
  - `plan = "provider"`
  - `5H = "-"`, `weekly = "-"`, `last = "-"` or `last_used_at`

- [ ] **Step 4: Switch list/switch/remove to target rows and branch activation by target kind**

Update `src/main.zig`:

```zig
switch (selected.kind) {
    .account => {
        try provider_config.clearManagedProviderProfile(allocator, codex_home);
        try registry.activateAccountByKey(allocator, codex_home, &reg, selected.account_key.?);
    },
    .provider_profile => {
        const profile = reg.provider_profiles.items[selected.provider_profile_index.?];
        try provider_config.applyManagedProviderProfile(allocator, codex_home, .{
            .provider_id = profile.provider_id,
            .base_url = profile.base_url,
            .api_key = profile.api_key,
            .wire_api = profile.wire_api,
            .model = profile.model,
        });
        try registry.setActiveProviderProfile(allocator, &reg, profile.profile_id);
    },
}
```

Update matching:

```zig
const matches_label = std.ascii.indexOfIgnoreCase(profile.label, query) != null;
const matches_provider_id = std.ascii.indexOfIgnoreCase(profile.provider_id, query) != null;
```

Update remove fallback:

```zig
const replacement = if (has_remaining_accounts)
    .{ .kind = .account, .id = best_account_key.? }
else if (has_remaining_provider_profiles)
    .{ .kind = .provider_profile, .id = first_provider_profile_id.? }
else
    null;
```

- [ ] **Step 5: Re-run mixed-target tests and commit**

Run:

```bash
env HOME=/tmp/codex-auth-provider-profile zig test src/main.zig -lc --test-filter "provider profile"
env HOME=/tmp/codex-auth-provider-profile zig test src/main.zig -lc --test-filter "mixed-target"
```

Expected: PASS for mixed row rendering and switch/remove target selection tests.

Commit:

```bash
git add src/target_rows.zig src/format.zig src/cli.zig src/main.zig src/tests/target_rows_test.zig src/tests/e2e_cli_test.zig
git commit -m "feat: unify provider profiles with account switching"
```

### Task 5: Make Status, Refresh, and Auto-Switch Provider-Aware

**Files:**
- Modify: `src/auto.zig`
- Modify: `src/main.zig`
- Modify: `src/registry.zig`
- Modify: `src/tests/main_test.zig`
- Modify: `src/tests/e2e_cli_test.zig`

- [ ] **Step 1: Write failing status and refresh-guard tests**

```zig
test "Scenario: Given active provider profile when rendering status then auth is provider and usage is unsupported" {
    const status = auto.Status{
        .enabled = false,
        .runtime = .disabled,
        .threshold_5h_percent = 10,
        .threshold_weekly_percent = 5,
        .api_usage_enabled = true,
        .api_account_enabled = true,
        .active_target_kind = .provider_profile,
        .active_target_label = "openrouter",
    };

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try auto.writeStatus(&aw.writer, status);
    const rendered = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "auth: provider") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "usage: unsupported") != null);
}
```

- [ ] **Step 2: Run provider-active status tests and confirm they fail**

Run:

```bash
env HOME=/tmp/codex-auth-provider-profile zig test src/main.zig -lc --test-filter "auth is provider"
```

Expected: FAIL because `Status` has no active-target fields and refresh paths still assume accounts only.

- [ ] **Step 3: Extend status output and add active-target helpers**

Extend `auto.Status` and `getStatus`:

```zig
pub const Status = struct {
    enabled: bool,
    runtime: RuntimeState,
    threshold_5h_percent: u8,
    threshold_weekly_percent: u8,
    api_usage_enabled: bool,
    api_account_enabled: bool,
    active_target_kind: ?registry.ActiveTargetKind,
    active_target_label: ?[]const u8,
};
```

Render provider-active status explicitly:

```zig
try out.writeAll("auth: ");
try out.writeAll(switch (status.active_target_kind orelse .account) {
    .account => "chatgpt",
    .provider_profile => "provider",
});
try out.writeAll("\n");

if (status.active_target_kind == .provider_profile) {
    try out.writeAll("usage: unsupported\n");
} else {
    try out.writeAll("usage: ");
    try out.writeAll(if (status.api_usage_enabled) "api" else "local");
    try out.writeAll("\n");
}
```

- [ ] **Step 4: Guard refresh and daemon paths so provider-active state is skipped**

Add early returns wherever account-only refresh currently assumes `active_account_key`:

```zig
if (reg.active_target_kind == .provider_profile) return false;
const account_key = registry.activeAccountKey(reg) orelse return false;
```

Apply this guard to:

- `main.shouldRefreshAllAccountUsageForList`
- `auto.refreshActiveUsage*`
- `auto.refreshActiveAccountNamesForDaemonWithFetcher`
- `main.refreshAccountNamesForActiveAuth`
- `registry.syncActiveAccountFromAuth` call sites that should only run when `auth.json` remains authoritative

- [ ] **Step 5: Re-run provider-active tests and commit**

Run:

```bash
env HOME=/tmp/codex-auth-provider-profile zig test src/main.zig -lc --test-filter "provider"
```

Expected: PASS for provider-active status and refresh-guard tests.

Commit:

```bash
git add src/auto.zig src/main.zig src/registry.zig src/tests/main_test.zig src/tests/e2e_cli_test.zig
git commit -m "feat: skip account refresh flows for provider profiles"
```

### Task 6: Update Docs And Run Full Verification

**Files:**
- Modify: `README.md`
- Modify: `docs/implement.md`
- Modify: `src/main.zig`

- [ ] **Step 1: Add failing doc-adjacent e2e assertions for provider command help**

```zig
test "Scenario: Given help output when rendering then provider commands are documented" {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try cli.writeHelp(&aw.writer, false, &registry.defaultAutoSwitchConfig(), &registry.defaultApiConfig());
    const help = aw.written();

    try std.testing.expect(std.mem.indexOf(u8, help, "provider add") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "provider update") != null);
}
```

- [ ] **Step 2: Run the targeted help test and confirm it fails**

Run:

```bash
env HOME=/tmp/codex-auth-provider-profile zig test src/main.zig -lc --test-filter "provider commands are documented"
```

Expected: FAIL because help/docs do not mention provider profiles yet.

- [ ] **Step 3: Update README and implementation docs**

Add command docs to `README.md`:

```md
| `codex-auth provider add <label> --base-url <url> --api-key <key>` | Add a managed third-party provider profile |
| `codex-auth provider list` | List managed provider profiles |
| `codex-auth provider update <query>` | Update a managed provider profile |
| `codex-auth provider remove <query>` | Remove a managed provider profile |
```

Document the managed block approach in `docs/implement.md`:

```md
## Provider Profiles

- Provider profiles are stored in `registry.json` under `provider_profiles`.
- Activating a provider profile rewrites only the codex-auth-managed block inside `~/.codex/config.toml`.
- Provider profiles do not participate in usage refresh or auto-switch in this version.
```

- [ ] **Step 4: Run the full test suite and required `zig build run -- list` verification**

Run:

```bash
mkdir -p /tmp/codex-auth-provider-profile
env HOME=/tmp/codex-auth-provider-profile zig test src/main.zig -lc
env HOME=/tmp/codex-auth-provider-profile zig build run -- list
```

Expected:

- `zig test src/main.zig -lc` exits 0
- `zig build run -- list` exits 0 and prints a valid table or an empty-state table without crashing

- [ ] **Step 5: Commit the docs and final verification changes**

```bash
git add README.md docs/implement.md src/main.zig
git commit -m "docs: describe provider profile switching"
```

## Self-Review Notes

- Spec coverage:
  - registry/provider-profile model: Tasks 1 and 3
  - config-driven activation: Tasks 2 and 4
  - unified list/switch/remove: Task 4
  - status and refresh boundaries: Task 5
  - docs/help: Task 6
- Placeholder scan:
  - no `TODO`, `TBD`, or "similar to" references remain
- Type consistency:
  - `ActiveTargetKind`, `ProviderProfile`, `ManagedProviderConfig`, and `TargetKind` are used consistently across later tasks
