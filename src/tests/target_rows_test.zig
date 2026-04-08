const std = @import("std");
const registry = @import("../registry.zig");
const target_rows = @import("../target_rows.zig");

fn makeEmptyRegistry() registry.Registry {
    return .{
        .schema_version = registry.current_schema_version,
        .active_account_key = null,
        .active_account_activated_at_ms = null,
        .active_target_kind = null,
        .active_target_id = null,
        .auto_switch = registry.defaultAutoSwitchConfig(),
        .api = registry.defaultApiConfig(),
        .accounts = std.ArrayList(registry.AccountRecord).empty,
        .provider_profiles = std.ArrayList(registry.ProviderProfile).empty,
    };
}

fn appendAccount(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    record_key: []const u8,
    email: []const u8,
    alias: []const u8,
    plan: registry.PlanType,
) !void {
    const sep = std.mem.lastIndexOf(u8, record_key, "::") orelse return error.InvalidRecordKey;
    const chatgpt_user_id = record_key[0..sep];
    const chatgpt_account_id = record_key[sep + 2 ..];
    try reg.accounts.append(allocator, .{
        .account_key = try allocator.dupe(u8, record_key),
        .chatgpt_account_id = try allocator.dupe(u8, chatgpt_account_id),
        .chatgpt_user_id = try allocator.dupe(u8, chatgpt_user_id),
        .email = try allocator.dupe(u8, email),
        .alias = try allocator.dupe(u8, alias),
        .account_name = null,
        .plan = plan,
        .auth_mode = .chatgpt,
        .created_at = 1,
        .last_used_at = null,
        .last_usage = null,
        .last_usage_at = null,
        .last_local_rollout = null,
    });
}

fn appendProvider(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    profile_id: []const u8,
    label: []const u8,
    last_used_at: ?i64,
) !void {
    try reg.provider_profiles.append(allocator, .{
        .profile_id = try allocator.dupe(u8, profile_id),
        .label = try allocator.dupe(u8, label),
        .provider_id = try allocator.dupe(u8, profile_id),
        .base_url = try allocator.dupe(u8, "https://example.com/v1"),
        .api_key = try allocator.dupe(u8, "sk-test"),
        .wire_api = try allocator.dupe(u8, "responses"),
        .model = null,
        .created_at = 1,
        .last_used_at = last_used_at,
    });
}

test "Scenario: Given account and provider targets when building target rows then both sections are selectable" {
    const gpa = std.testing.allocator;
    var reg = makeEmptyRegistry();
    defer reg.deinit(gpa);

    try appendAccount(gpa, &reg, "user-a::acct-a", "alpha@example.com", "", .team);
    try appendProvider(gpa, &reg, "openrouter", "OpenRouter", null);
    try registry.setActiveProviderProfile(gpa, &reg, "openrouter");

    var rows = try target_rows.buildTargetRows(gpa, &reg, null);
    defer rows.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 3), rows.rows.len);
    try std.testing.expectEqual(@as(usize, 2), rows.selectable_row_indices.len);
    try std.testing.expect(rows.rows[0].kind == .account);
    try std.testing.expect(rows.rows[1].is_header);
    try std.testing.expect(rows.rows[1].kind == .provider_profile);
    try std.testing.expect(rows.rows[2].kind == .provider_profile);
}

test "Scenario: Given active provider target when building target rows then provider row is marked active" {
    const gpa = std.testing.allocator;
    var reg = makeEmptyRegistry();
    defer reg.deinit(gpa);

    try appendAccount(gpa, &reg, "user-a::acct-a", "alpha@example.com", "", .team);
    try appendProvider(gpa, &reg, "openrouter", "OpenRouter", 123);
    try appendProvider(gpa, &reg, "proxy", "Proxy", null);
    try registry.setActiveProviderProfile(gpa, &reg, "openrouter");

    var rows = try target_rows.buildTargetRows(gpa, &reg, null);
    defer rows.deinit(gpa);

    try std.testing.expect(rows.rows[2].is_active);
    try std.testing.expectEqual(target_rows.TargetKind.provider_profile, rows.rows[2].kind);
    try std.testing.expectEqualStrings("provider", rows.rows[2].plan_cell);
    try std.testing.expectEqualStrings("-", rows.rows[2].rate_5h_cell);
    try std.testing.expectEqualStrings("-", rows.rows[2].rate_week_cell);
    try std.testing.expect(rows.rows[2].last_cell.len > 0);
}

test "Scenario: Given mixed target refs when building target rows then only requested rows are rendered" {
    const gpa = std.testing.allocator;
    var reg = makeEmptyRegistry();
    defer reg.deinit(gpa);

    try appendAccount(gpa, &reg, "user-a::acct-a", "alpha@example.com", "", .team);
    try appendAccount(gpa, &reg, "user-b::acct-b", "beta@example.com", "", .pro);
    try appendProvider(gpa, &reg, "openrouter", "OpenRouter", null);
    try appendProvider(gpa, &reg, "proxy", "Proxy", null);

    const refs = [_]target_rows.TargetRef{
        .{ .account = 1 },
        .{ .provider_profile = 0 },
    };
    var rows = try target_rows.buildTargetRows(gpa, &reg, &refs);
    defer rows.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 3), rows.rows.len);
    try std.testing.expectEqual(@as(usize, 2), rows.selectable_row_indices.len);
    try std.testing.expectEqualStrings("beta@example.com", rows.rows[0].account_cell);
    try std.testing.expectEqualStrings("OpenRouter", rows.rows[2].account_cell);
}
