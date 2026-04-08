const std = @import("std");
const registry = @import("registry.zig");

pub const ConfigProvider = struct {
    provider_id: []u8,
    label: []u8,
    base_url: []u8,
    wire_api: []u8,
    auth_token: ?[]u8,

    fn deinit(self: *ConfigProvider, allocator: std.mem.Allocator) void {
        allocator.free(self.provider_id);
        allocator.free(self.label);
        allocator.free(self.base_url);
        allocator.free(self.wire_api);
        if (self.auth_token) |value| allocator.free(value);
    }
};

pub const ProviderScan = struct {
    active_provider_id: ?[]u8,
    providers: std.ArrayList(ConfigProvider),

    pub fn deinit(self: *ProviderScan, allocator: std.mem.Allocator) void {
        if (self.active_provider_id) |value| allocator.free(value);
        for (self.providers.items) |*provider| provider.deinit(allocator);
        self.providers.deinit(allocator);
    }
};

fn configPath(allocator: std.mem.Allocator, codex_home: []const u8) ![]u8 {
    return try std.fs.path.join(allocator, &[_][]const u8{ codex_home, "config.toml" });
}

fn readFileOrEmpty(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return allocator.alloc(u8, 0),
        else => return err,
    };
    defer file.close();
    return try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
}

fn writeFile(path: []const u8, data: []const u8) !void {
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(data);
}

fn trimSpace(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t\r");
}

fn stripCommentPrefix(line: []const u8) []const u8 {
    var trimmed = std.mem.trimLeft(u8, line, " \t");
    if (trimmed.len > 0 and trimmed[0] == '#') {
        trimmed = std.mem.trimLeft(u8, trimmed[1..], " \t");
    }
    return trimmed;
}

fn parseQuotedValue(allocator: std.mem.Allocator, line: []const u8, key: []const u8) !?[]u8 {
    const trimmed = trimSpace(line);
    if (!std.mem.startsWith(u8, trimmed, key)) return null;
    var rest = trimSpace(trimmed[key.len..]);
    if (rest.len == 0 or rest[0] != '=') return null;
    rest = trimSpace(rest[1..]);
    if (rest.len < 2 or rest[0] != '"') return null;
    const closing = std.mem.indexOfPos(u8, rest, 1, "\"") orelse return null;
    return try allocator.dupe(u8, rest[1..closing]);
}

fn firstTableStartIndex(text: []const u8) usize {
    var start: usize = 0;
    while (start < text.len) {
        const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
        const line = text[start..end];
        if (trimSpace(line).len > 0 and trimSpace(line)[0] == '[') return start;
        start = if (end < text.len) end + 1 else text.len;
    }
    return text.len;
}

fn parseActiveProviderIdFromPreamble(allocator: std.mem.Allocator, preamble: []const u8) !?[]u8 {
    var start: usize = 0;
    while (start < preamble.len) {
        const end = std.mem.indexOfScalarPos(u8, preamble, start, '\n') orelse preamble.len;
        const line = preamble[start..end];
        const trimmed = trimSpace(line);
        if (trimmed.len == 0 or trimmed[0] == '#') {
            start = if (end < preamble.len) end + 1 else preamble.len;
            continue;
        }
        if (try parseQuotedValue(allocator, trimmed, "model_provider")) |value| {
            return value;
        }
        start = if (end < preamble.len) end + 1 else preamble.len;
    }
    return null;
}

fn parseProviderIdFromHeader(allocator: std.mem.Allocator, line: []const u8) !?[]u8 {
    const trimmed = trimSpace(line);
    const prefix = "[model_providers.";
    if (!std.mem.startsWith(u8, trimmed, prefix) or trimmed.len < prefix.len + 2) return null;
    if (trimmed[trimmed.len - 1] != ']') return null;
    const inner = trimmed[prefix.len .. trimmed.len - 1];
    if (inner.len >= 2 and inner[0] == '"' and inner[inner.len - 1] == '"') {
        return try allocator.dupe(u8, inner[1 .. inner.len - 1]);
    }
    return try allocator.dupe(u8, inner);
}

pub fn scanProvidersFromText(allocator: std.mem.Allocator, text: []const u8) !ProviderScan {
    var scan = ProviderScan{
        .active_provider_id = null,
        .providers = std.ArrayList(ConfigProvider).empty,
    };
    errdefer scan.deinit(allocator);

    const first_table_start = firstTableStartIndex(text);
    scan.active_provider_id = try parseActiveProviderIdFromPreamble(allocator, text[0..first_table_start]);

    var current: ?ConfigProvider = null;
    errdefer if (current) |*provider| provider.deinit(allocator);

    var start: usize = first_table_start;
    while (start < text.len) {
        const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
        const line = text[start..end];
        const trimmed = trimSpace(line);

        if (trimmed.len > 0 and trimmed[0] == '[') {
            if (current) |provider| {
                try scan.providers.append(allocator, provider);
                current = null;
            }
            if (try parseProviderIdFromHeader(allocator, trimmed)) |provider_id| {
                current = ConfigProvider{
                    .provider_id = provider_id,
                    .label = try allocator.dupe(u8, provider_id),
                    .base_url = try allocator.dupe(u8, ""),
                    .wire_api = try allocator.dupe(u8, ""),
                    .auth_token = null,
                };
            }
            start = if (end < text.len) end + 1 else text.len;
            continue;
        }

        if (current) |*provider| {
            if (try parseQuotedValue(allocator, trimmed, "name")) |value| {
                allocator.free(provider.label);
                provider.label = value;
            } else if (try parseQuotedValue(allocator, trimmed, "base_url")) |value| {
                allocator.free(provider.base_url);
                provider.base_url = value;
            } else if (try parseQuotedValue(allocator, trimmed, "wire_api")) |value| {
                allocator.free(provider.wire_api);
                provider.wire_api = value;
            } else if (try parseQuotedValue(allocator, trimmed, "experimental_bearer_token")) |value| {
                if (provider.auth_token) |old| allocator.free(old);
                provider.auth_token = value;
            } else if (try parseQuotedValue(allocator, trimmed, "api_key")) |value| {
                if (provider.auth_token) |old| allocator.free(old);
                provider.auth_token = value;
            }
        }

        start = if (end < text.len) end + 1 else text.len;
    }

    if (current) |provider| {
        try scan.providers.append(allocator, provider);
    }

    return scan;
}

pub fn scanProviders(allocator: std.mem.Allocator, codex_home: []const u8) !ProviderScan {
    const path = try configPath(allocator, codex_home);
    defer allocator.free(path);
    const existing = try readFileOrEmpty(allocator, path);
    defer allocator.free(existing);
    return try scanProvidersFromText(allocator, existing);
}

fn rewriteDirectiveLine(
    allocator: std.mem.Allocator,
    existing_line: ?[]const u8,
    key: []const u8,
    value: []const u8,
    enabled: bool,
) ![]u8 {
    if (enabled) {
        return std.fmt.allocPrint(allocator, "{s} = \"{s}\"", .{ key, value });
    }

    if (existing_line) |line| {
        const uncommented = stripCommentPrefix(line);
        if (uncommented.len > 0) return std.fmt.allocPrint(allocator, "# {s}", .{uncommented});
    }
    return std.fmt.allocPrint(allocator, "# {s} = \"{s}\"", .{ key, value });
}

fn rewritePreamble(
    allocator: std.mem.Allocator,
    preamble: []const u8,
    provider_id: ?[]const u8,
) ![]u8 {
    var other_lines = std.ArrayList([]u8).empty;
    defer {
        for (other_lines.items) |line| allocator.free(line);
        other_lines.deinit(allocator);
    }

    var model_line_existing: ?[]u8 = null;
    defer if (model_line_existing) |line| allocator.free(line);
    var auth_line_existing: ?[]u8 = null;
    defer if (auth_line_existing) |line| allocator.free(line);

    var start: usize = 0;
    while (start < preamble.len) {
        const end = std.mem.indexOfScalarPos(u8, preamble, start, '\n') orelse preamble.len;
        const line = preamble[start..end];
        const trimmed = stripCommentPrefix(line);
        if (std.mem.startsWith(u8, trimmed, "model_provider")) {
            model_line_existing = try allocator.dupe(u8, trimSpace(line));
        } else if (std.mem.startsWith(u8, trimmed, "preferred_auth_method")) {
            auth_line_existing = try allocator.dupe(u8, trimSpace(line));
        } else {
            try other_lines.append(allocator, try allocator.dupe(u8, line));
        }
        start = if (end < preamble.len) end + 1 else preamble.len;
    }

    const resolved_provider_id = if (provider_id) |value|
        try allocator.dupe(u8, value)
    else blk: {
        if (model_line_existing) |line| {
            if (try parseQuotedValue(allocator, stripCommentPrefix(line), "model_provider")) |value| {
                defer allocator.free(value);
                break :blk try allocator.dupe(u8, value);
            }
        }
        break :blk try allocator.dupe(u8, "openai");
    };
    defer allocator.free(resolved_provider_id);

    const model_line = try rewriteDirectiveLine(allocator, model_line_existing, "model_provider", resolved_provider_id, provider_id != null);
    defer allocator.free(model_line);
    const auth_line = try rewriteDirectiveLine(allocator, auth_line_existing, "preferred_auth_method", "apikey", provider_id != null);
    defer allocator.free(auth_line);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, model_line);
    try out.append(allocator, '\n');

    var inserted_auth = false;
    if (other_lines.items.len == 0) {
        try out.appendSlice(allocator, auth_line);
        try out.append(allocator, '\n');
        inserted_auth = true;
    } else {
        for (other_lines.items, 0..) |line, idx| {
            try out.appendSlice(allocator, line);
            try out.append(allocator, '\n');
            const stripped = stripCommentPrefix(line);
            if (!inserted_auth and std.mem.startsWith(u8, stripped, "disable_response_storage")) {
                try out.appendSlice(allocator, auth_line);
                try out.append(allocator, '\n');
                inserted_auth = true;
            } else if (!inserted_auth and idx + 1 == other_lines.items.len) {
                try out.appendSlice(allocator, auth_line);
                try out.append(allocator, '\n');
                inserted_auth = true;
            }
        }
    }

    return try out.toOwnedSlice(allocator);
}

fn rewriteConfigSelection(
    allocator: std.mem.Allocator,
    existing: []const u8,
    provider_id: ?[]const u8,
) ![]u8 {
    const first_table_start = firstTableStartIndex(existing);
    const preamble = existing[0..first_table_start];
    const rest = existing[first_table_start..];

    const new_preamble = try rewritePreamble(allocator, preamble, provider_id);
    defer allocator.free(new_preamble);

    if (rest.len == 0) return allocator.dupe(u8, std.mem.trimRight(u8, new_preamble, "\n"));
    return std.mem.concat(allocator, u8, &[_][]const u8{
        std.mem.trimRight(u8, new_preamble, "\n"),
        "\n\n",
        std.mem.trimLeft(u8, rest, "\n"),
    });
}

pub fn applyProviderSelection(allocator: std.mem.Allocator, codex_home: []const u8, provider_id: []const u8) !void {
    const path = try configPath(allocator, codex_home);
    defer allocator.free(path);

    const existing = try readFileOrEmpty(allocator, path);
    defer allocator.free(existing);
    const rendered = try rewriteConfigSelection(allocator, existing, provider_id);
    defer allocator.free(rendered);
    try writeFile(path, rendered);
}

pub fn clearProviderSelection(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    const path = try configPath(allocator, codex_home);
    defer allocator.free(path);

    const existing = try readFileOrEmpty(allocator, path);
    defer allocator.free(existing);
    const rendered = try rewriteConfigSelection(allocator, existing, null);
    defer allocator.free(rendered);
    try writeFile(path, rendered);
}

fn providerProfilesEqual(a: *const registry.ProviderProfile, b: *const registry.ProviderProfile) bool {
    return std.mem.eql(u8, a.profile_id, b.profile_id) and
        std.mem.eql(u8, a.label, b.label) and
        std.mem.eql(u8, a.provider_id, b.provider_id) and
        std.mem.eql(u8, a.base_url, b.base_url) and
        std.mem.eql(u8, a.api_key, b.api_key) and
        std.mem.eql(u8, a.wire_api, b.wire_api) and
        ((a.model == null and b.model == null) or
            (a.model != null and b.model != null and std.mem.eql(u8, a.model.?, b.model.?))) and
        a.last_used_at == b.last_used_at;
}

pub fn syncRegistryProvidersFromConfig(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
) !bool {
    var scan = try scanProviders(allocator, codex_home);
    defer scan.deinit(allocator);

    const old_active_kind = reg.active_target_kind;
    const old_active_id = if (reg.active_target_id) |value|
        try allocator.dupe(u8, value)
    else
        null;
    defer if (old_active_id) |value| allocator.free(value);
    const old_len = reg.provider_profiles.items.len;

    var replacements = std.ArrayList(registry.ProviderProfile).empty;
    var moved_profiles: usize = 0;
    defer {
        for (replacements.items[moved_profiles..]) |*profile| {
            allocator.free(profile.profile_id);
            allocator.free(profile.label);
            allocator.free(profile.provider_id);
            allocator.free(profile.base_url);
            allocator.free(profile.api_key);
            allocator.free(profile.wire_api);
            if (profile.model) |value| allocator.free(value);
        }
        replacements.deinit(allocator);
    }

    for (scan.providers.items) |provider| {
        const existing_idx = registry.findProviderProfileIndexById(reg, provider.provider_id);
        const created_at = if (existing_idx) |idx| reg.provider_profiles.items[idx].created_at else std.time.timestamp();
        const last_used_at = if (existing_idx) |idx| reg.provider_profiles.items[idx].last_used_at else null;
        try replacements.append(allocator, .{
            .profile_id = try allocator.dupe(u8, provider.provider_id),
            .label = try allocator.dupe(u8, provider.label),
            .provider_id = try allocator.dupe(u8, provider.provider_id),
            .base_url = try allocator.dupe(u8, provider.base_url),
            .api_key = if (provider.auth_token) |value| try allocator.dupe(u8, value) else try allocator.dupe(u8, ""),
            .wire_api = try allocator.dupe(u8, provider.wire_api),
            .model = null,
            .created_at = created_at,
            .last_used_at = last_used_at,
        });
    }

    var changed = old_len != replacements.items.len;
    if (!changed and old_len == replacements.items.len) {
        for (reg.provider_profiles.items, replacements.items) |*old_profile, *new_profile| {
            if (!providerProfilesEqual(old_profile, new_profile)) {
                changed = true;
                break;
            }
        }
    }

    registry.clearProviderProfiles(allocator, reg);
    for (replacements.items) |*profile| {
        try reg.provider_profiles.append(allocator, profile.*);
        moved_profiles += 1;
    }

    if (scan.active_provider_id) |active_id| {
        if (registry.findProviderProfileIndexById(reg, active_id) != null) {
            try registry.setActiveProviderProfile(allocator, reg, active_id);
        }
    } else if (reg.active_target_kind == .provider_profile) {
        if (reg.active_target_id) |value| {
            allocator.free(value);
            reg.active_target_id = null;
        }
        reg.active_target_kind = null;
    }

    const new_active_id = if (reg.active_target_kind == .provider_profile) reg.active_target_id else null;
    if (old_active_kind != reg.active_target_kind) changed = true;
    if (old_active_id == null and new_active_id != null) changed = true;
    if (old_active_id != null and new_active_id == null) changed = true;
    if (old_active_id != null and new_active_id != null and !std.mem.eql(u8, old_active_id.?, new_active_id.?)) changed = true;

    return changed;
}
