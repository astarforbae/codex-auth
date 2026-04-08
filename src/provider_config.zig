const std = @import("std");

pub const managed_begin = "# BEGIN codex-auth managed provider";
pub const managed_end = "# END codex-auth managed provider";

pub const ManagedProviderConfig = struct {
    provider_id: []const u8,
    base_url: []const u8,
    api_key: []const u8,
    wire_api: []const u8,
    model: ?[]const u8,
};

const ManagedRange = struct {
    start: usize,
    end: usize,
};

fn configPath(allocator: std.mem.Allocator, codex_home: []const u8) ![]u8 {
    return try std.fs.path.join(allocator, &[_][]const u8{ codex_home, "config.toml" });
}

fn escapeTomlString(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    for (raw) |ch| {
        switch (ch) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '"' => try out.appendSlice(allocator, "\\\""),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, ch),
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn findManagedRange(existing: []const u8) ?ManagedRange {
    const begin = std.mem.indexOf(u8, existing, managed_begin) orelse return null;
    const end_marker = std.mem.indexOfPos(u8, existing, begin, managed_end) orelse return null;
    var end = end_marker + managed_end.len;
    if (end < existing.len and existing[end] == '\n') {
        end += 1;
    }
    return .{ .start = begin, .end = end };
}

fn renderWithoutManagedBlock(allocator: std.mem.Allocator, existing: []const u8) ![]u8 {
    const range = findManagedRange(existing) orelse return allocator.dupe(u8, existing);
    const before = std.mem.trimRight(u8, existing[0..range.start], "\n");
    const after = std.mem.trimLeft(u8, existing[range.end..], "\n");

    if (before.len == 0 and after.len == 0) {
        return allocator.alloc(u8, 0);
    }
    if (before.len == 0) {
        return allocator.dupe(u8, after);
    }
    if (after.len == 0) {
        return std.mem.concat(allocator, u8, &[_][]const u8{ before, "\n" });
    }
    return std.mem.concat(allocator, u8, &[_][]const u8{ before, "\n\n", after });
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

pub fn renderManagedProviderBlockAlloc(
    allocator: std.mem.Allocator,
    cfg: ManagedProviderConfig,
) ![]u8 {
    const provider_id = try escapeTomlString(allocator, cfg.provider_id);
    defer allocator.free(provider_id);
    const base_url = try escapeTomlString(allocator, cfg.base_url);
    defer allocator.free(base_url);
    const api_key = try escapeTomlString(allocator, cfg.api_key);
    defer allocator.free(api_key);
    const wire_api = try escapeTomlString(allocator, cfg.wire_api);
    defer allocator.free(wire_api);

    if (cfg.model) |model_value| {
        const model = try escapeTomlString(allocator, model_value);
        defer allocator.free(model);
        return std.fmt.allocPrint(
            allocator,
            "{s}\nmodel_provider = \"{s}\"\n\n[model_providers.\"{s}\"]\nbase_url = \"{s}\"\napi_key = \"{s}\"\nwire_api = \"{s}\"\nmodel = \"{s}\"\n{s}\n",
            .{ managed_begin, provider_id, provider_id, base_url, api_key, wire_api, model, managed_end },
        );
    }

    return std.fmt.allocPrint(
        allocator,
        "{s}\nmodel_provider = \"{s}\"\n\n[model_providers.\"{s}\"]\nbase_url = \"{s}\"\napi_key = \"{s}\"\nwire_api = \"{s}\"\n{s}\n",
        .{ managed_begin, provider_id, provider_id, base_url, api_key, wire_api, managed_end },
    );
}

pub fn renderManagedProviderConfig(
    allocator: std.mem.Allocator,
    existing: []const u8,
    cfg: ManagedProviderConfig,
) ![]u8 {
    const block = try renderManagedProviderBlockAlloc(allocator, cfg);
    defer allocator.free(block);

    if (findManagedRange(existing)) |range| {
        return std.mem.concat(allocator, u8, &[_][]const u8{
            existing[0..range.start],
            block,
            existing[range.end..],
        });
    }

    const trimmed = std.mem.trimRight(u8, existing, "\n");
    if (trimmed.len == 0) {
        return allocator.dupe(u8, block);
    }
    return std.mem.concat(allocator, u8, &[_][]const u8{ trimmed, "\n\n", block });
}

pub fn clearManagedProviderConfig(
    allocator: std.mem.Allocator,
    existing: []const u8,
) ![]u8 {
    return renderWithoutManagedBlock(allocator, existing);
}

pub fn applyManagedProviderProfile(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    cfg: ManagedProviderConfig,
) !void {
    const path = try configPath(allocator, codex_home);
    defer allocator.free(path);

    const existing = try readFileOrEmpty(allocator, path);
    defer allocator.free(existing);
    const rendered = try renderManagedProviderConfig(allocator, existing, cfg);
    defer allocator.free(rendered);

    try writeFile(path, rendered);
}

pub fn clearManagedProviderProfile(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
) !void {
    const path = try configPath(allocator, codex_home);
    defer allocator.free(path);

    const existing = try readFileOrEmpty(allocator, path);
    defer allocator.free(existing);

    if (findManagedRange(existing) == null) return;

    const rendered = try clearManagedProviderConfig(allocator, existing);
    defer allocator.free(rendered);
    try writeFile(path, rendered);
}
