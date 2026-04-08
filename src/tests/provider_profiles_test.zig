const std = @import("std");
const registry = @import("../registry.zig");

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

fn makeProviderProfile(
    allocator: std.mem.Allocator,
    profile_id: []const u8,
    label: []const u8,
    provider_id: []const u8,
    base_url: []const u8,
    api_key: []const u8,
    wire_api: []const u8,
    model: ?[]const u8,
    created_at: i64,
    last_used_at: ?i64,
) !registry.ProviderProfile {
    return .{
        .profile_id = try allocator.dupe(u8, profile_id),
        .label = try allocator.dupe(u8, label),
        .provider_id = try allocator.dupe(u8, provider_id),
        .base_url = try allocator.dupe(u8, base_url),
        .api_key = try allocator.dupe(u8, api_key),
        .wire_api = try allocator.dupe(u8, wire_api),
        .model = if (model) |value| try allocator.dupe(u8, value) else null,
        .created_at = created_at,
        .last_used_at = last_used_at,
    };
}

test "Scenario: Given provider profile active target helpers then account and provider ids are resolved" {
    const gpa = std.testing.allocator;
    var reg = makeEmptyRegistry();
    defer reg.deinit(gpa);

    try registry.setActiveProviderProfile(gpa, &reg, "openrouter");

    try std.testing.expect(reg.active_target_kind != null);
    try std.testing.expectEqual(registry.ActiveTargetKind.provider_profile, reg.active_target_kind.?);
    try std.testing.expect(registry.activeAccountKey(&reg) == null);
    try std.testing.expectEqualStrings("openrouter", registry.activeProviderProfileId(&reg).?);
}

test "Scenario: Given provider profile upserts then sorting is deterministic and updates replace in place" {
    const gpa = std.testing.allocator;
    var reg = makeEmptyRegistry();
    defer reg.deinit(gpa);

    try registry.upsertProviderProfile(gpa, &reg, try makeProviderProfile(
        gpa,
        "zeta",
        "Zeta",
        "zeta",
        "https://example.com/zeta",
        "sk-zeta",
        "responses",
        null,
        10,
        null,
    ));
    try registry.upsertProviderProfile(gpa, &reg, try makeProviderProfile(
        gpa,
        "alpha",
        "Alpha",
        "alpha",
        "https://example.com/alpha",
        "sk-alpha",
        "responses",
        "gpt-5.4",
        20,
        null,
    ));
    try std.testing.expectEqualStrings("alpha", reg.provider_profiles.items[0].profile_id);
    try std.testing.expectEqualStrings("zeta", reg.provider_profiles.items[1].profile_id);

    try registry.upsertProviderProfile(gpa, &reg, try makeProviderProfile(
        gpa,
        "alpha",
        "Alpha Prime",
        "alpha",
        "https://example.com/alpha-v2",
        "sk-alpha-v2",
        "responses",
        "gpt-5.4",
        99,
        42,
    ));
    try std.testing.expectEqual(@as(usize, 2), reg.provider_profiles.items.len);
    try std.testing.expectEqualStrings("Alpha Prime", reg.provider_profiles.items[0].label);
    try std.testing.expectEqualStrings("https://example.com/alpha-v2", reg.provider_profiles.items[0].base_url);
    try std.testing.expectEqual(@as(i64, 20), reg.provider_profiles.items[0].created_at);
}

test "Scenario: Given provider profile remove helper then requested item is removed" {
    const gpa = std.testing.allocator;
    var reg = makeEmptyRegistry();
    defer reg.deinit(gpa);

    try registry.upsertProviderProfile(gpa, &reg, try makeProviderProfile(
        gpa,
        "alpha",
        "Alpha",
        "alpha",
        "https://example.com/alpha",
        "sk-alpha",
        "responses",
        null,
        1,
        null,
    ));
    try registry.upsertProviderProfile(gpa, &reg, try makeProviderProfile(
        gpa,
        "beta",
        "Beta",
        "beta",
        "https://example.com/beta",
        "sk-beta",
        "responses",
        null,
        2,
        null,
    ));

    try std.testing.expect(registry.removeProviderProfileById(gpa, &reg, "alpha"));
    try std.testing.expectEqual(@as(usize, 1), reg.provider_profiles.items.len);
    try std.testing.expectEqualStrings("beta", registry.firstProviderProfileId(&reg).?);
    try std.testing.expect(!registry.removeProviderProfileById(gpa, &reg, "missing"));
}
