const std = @import("std");
const builtin = @import("builtin");
const display_rows = @import("display_rows.zig");
const registry = @import("registry.zig");
const timefmt = @import("timefmt.zig");
const c = @cImport({
    @cInclude("time.h");
});

pub const TargetKind = enum {
    account,
    provider_profile,
};

pub const TargetRef = union(TargetKind) {
    account: usize,
    provider_profile: usize,
};

pub const TargetRow = struct {
    kind: TargetKind,
    account_index: ?usize,
    provider_profile_index: ?usize,
    account_cell: []u8,
    plan_cell: []u8,
    rate_5h_cell: []u8,
    rate_week_cell: []u8,
    last_cell: []u8,
    depth: u8,
    is_active: bool,
    is_header: bool,

    fn deinit(self: *TargetRow, allocator: std.mem.Allocator) void {
        allocator.free(self.account_cell);
        allocator.free(self.plan_cell);
        allocator.free(self.rate_5h_cell);
        allocator.free(self.rate_week_cell);
        allocator.free(self.last_cell);
    }
};

pub const TargetRows = struct {
    rows: []TargetRow,
    selectable_row_indices: []usize,

    pub fn deinit(self: *TargetRows, allocator: std.mem.Allocator) void {
        for (self.rows) |*row| row.deinit(allocator);
        allocator.free(self.rows);
        allocator.free(self.selectable_row_indices);
    }
};

pub fn buildTargetRows(
    allocator: std.mem.Allocator,
    reg: *const registry.Registry,
    refs: ?[]const TargetRef,
) !TargetRows {
    const account_indices = try filteredAccountIndicesAlloc(allocator, reg, refs);
    defer allocator.free(account_indices);
    var account_rows = try display_rows.buildDisplayRows(
        allocator,
        reg,
        if (refs != null) account_indices else null,
    );
    defer account_rows.deinit(allocator);

    var rows = std.ArrayList(TargetRow).empty;
    errdefer {
        for (rows.items) |*row| row.deinit(allocator);
        rows.deinit(allocator);
    }
    var selectable = std.ArrayList(usize).empty;
    errdefer selectable.deinit(allocator);

    for (account_rows.rows) |row| {
        const target_row = try buildAccountTargetRow(allocator, reg, row);
        rows.append(allocator, target_row) catch |err| {
            var owned = target_row;
            owned.deinit(allocator);
            return err;
        };
    }
    for (account_rows.selectable_row_indices) |row_idx| {
        try selectable.append(allocator, row_idx);
    }

    const provider_indices = try filteredProviderIndicesAlloc(allocator, reg, refs);
    defer allocator.free(provider_indices);
    if (provider_indices.len > 0) {
        const header_idx = rows.items.len;
        try rows.append(allocator, .{
            .kind = .provider_profile,
            .account_index = null,
            .provider_profile_index = null,
            .account_cell = try allocator.dupe(u8, "provider profiles"),
            .plan_cell = try allocator.dupe(u8, ""),
            .rate_5h_cell = try allocator.dupe(u8, ""),
            .rate_week_cell = try allocator.dupe(u8, ""),
            .last_cell = try allocator.dupe(u8, ""),
            .depth = 0,
            .is_active = false,
            .is_header = true,
        });
        _ = header_idx;

        for (provider_indices) |profile_idx| {
            const profile = &reg.provider_profiles.items[profile_idx];
            const provider_row = try buildProviderTargetRow(allocator, reg, profile, profile_idx);
            try rows.append(allocator, provider_row);
            try selectable.append(allocator, rows.items.len - 1);
        }
    }

    return .{
        .rows = try rows.toOwnedSlice(allocator),
        .selectable_row_indices = try selectable.toOwnedSlice(allocator),
    };
}

fn filteredAccountIndicesAlloc(
    allocator: std.mem.Allocator,
    reg: *const registry.Registry,
    refs: ?[]const TargetRef,
) ![]usize {
    if (refs == null) {
        const out = try allocator.alloc(usize, reg.accounts.items.len);
        for (out, 0..) |*slot, idx| slot.* = idx;
        return out;
    }

    var out = std.ArrayList(usize).empty;
    defer out.deinit(allocator);
    for (refs.?) |ref| {
        switch (ref) {
            .account => |idx| try out.append(allocator, idx),
            .provider_profile => {},
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn filteredProviderIndicesAlloc(
    allocator: std.mem.Allocator,
    reg: *const registry.Registry,
    refs: ?[]const TargetRef,
) ![]usize {
    if (refs == null) {
        const out = try allocator.alloc(usize, reg.provider_profiles.items.len);
        for (out, 0..) |*slot, idx| slot.* = idx;
        return out;
    }

    var out = std.ArrayList(usize).empty;
    defer out.deinit(allocator);
    for (refs.?) |ref| {
        switch (ref) {
            .account => {},
            .provider_profile => |idx| try out.append(allocator, idx),
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn buildAccountTargetRow(
    allocator: std.mem.Allocator,
    reg: *const registry.Registry,
    row: display_rows.DisplayRow,
) !TargetRow {
    if (row.account_index == null) {
        return .{
            .kind = .account,
            .account_index = null,
            .provider_profile_index = null,
            .account_cell = try allocator.dupe(u8, row.account_cell),
            .plan_cell = try allocator.dupe(u8, ""),
            .rate_5h_cell = try allocator.dupe(u8, ""),
            .rate_week_cell = try allocator.dupe(u8, ""),
            .last_cell = try allocator.dupe(u8, ""),
            .depth = row.depth,
            .is_active = false,
            .is_header = true,
        };
    }

    const rec = &reg.accounts.items[row.account_index.?];
    const plan = if (registry.resolvePlan(rec)) |p| @tagName(p) else "-";
    const rate_5h = try formatRateCellAlloc(allocator, rec.last_usage, 300, true);
    errdefer allocator.free(rate_5h);
    const rate_week = try formatRateCellAlloc(allocator, rec.last_usage, 10080, false);
    errdefer allocator.free(rate_week);
    const last_cell = try timefmt.formatRelativeTimeOrDashAlloc(allocator, rec.last_usage_at, std.time.timestamp());
    errdefer allocator.free(last_cell);

    return .{
        .kind = .account,
        .account_index = row.account_index,
        .provider_profile_index = null,
        .account_cell = try allocator.dupe(u8, row.account_cell),
        .plan_cell = try allocator.dupe(u8, plan),
        .rate_5h_cell = rate_5h,
        .rate_week_cell = rate_week,
        .last_cell = last_cell,
        .depth = row.depth,
        .is_active = row.is_active,
        .is_header = false,
    };
}

fn buildProviderTargetRow(
    allocator: std.mem.Allocator,
    reg: *const registry.Registry,
    profile: *const registry.ProviderProfile,
    profile_idx: usize,
) !TargetRow {
    const active_id = registry.activeProviderProfileId(reg);
    const is_active = active_id != null and std.mem.eql(u8, active_id.?, profile.profile_id);
    return .{
        .kind = .provider_profile,
        .account_index = null,
        .provider_profile_index = profile_idx,
        .account_cell = try allocator.dupe(u8, profile.label),
        .plan_cell = try allocator.dupe(u8, "provider"),
        .rate_5h_cell = try allocator.dupe(u8, "-"),
        .rate_week_cell = try allocator.dupe(u8, "-"),
        .last_cell = try timefmt.formatRelativeTimeOrDashAlloc(allocator, profile.last_used_at, std.time.timestamp()),
        .depth = 1,
        .is_active = is_active,
        .is_header = false,
    };
}

fn formatRateCellAlloc(
    allocator: std.mem.Allocator,
    usage: ?registry.RateLimitSnapshot,
    minutes: i64,
    fallback_primary: bool,
) ![]u8 {
    const window = resolveRateWindow(usage, minutes, fallback_primary) orelse return try allocator.dupe(u8, "-");
    if (window.resets_at == null) return try allocator.dupe(u8, "-");
    const reset_at = window.resets_at.?;
    const now = std.time.timestamp();
    if (now >= reset_at) return try allocator.dupe(u8, "100%");
    const remaining = remainingPercent(window.used_percent);
    var parts = try resetPartsAlloc(reset_at, now);
    defer parts.deinit();

    if (parts.same_day) {
        return std.fmt.allocPrint(allocator, "{d}% ({s})", .{ remaining, parts.time });
    }
    return std.fmt.allocPrint(allocator, "{d}% ({s} on {s})", .{ remaining, parts.time, parts.date });
}

fn resolveRateWindow(usage: ?registry.RateLimitSnapshot, minutes: i64, fallback_primary: bool) ?registry.RateLimitWindow {
    if (usage == null) return null;
    if (usage.?.primary) |p| {
        if (p.window_minutes != null and p.window_minutes.? == minutes) return p;
    }
    if (usage.?.secondary) |s| {
        if (s.window_minutes != null and s.window_minutes.? == minutes) return s;
    }
    return if (fallback_primary) usage.?.primary else usage.?.secondary;
}

fn remainingPercent(used: f64) i64 {
    const remaining = 100.0 - used;
    if (remaining <= 0.0) return 0;
    if (remaining >= 100.0) return 100;
    return @as(i64, @intFromFloat(remaining));
}

const ResetParts = struct {
    time: []u8,
    date: []u8,
    same_day: bool,

    fn deinit(self: *ResetParts) void {
        std.heap.page_allocator.free(self.time);
        std.heap.page_allocator.free(self.date);
    }
};

fn localtimeCompat(ts: i64, out_tm: *c.struct_tm) bool {
    if (comptime builtin.os.tag == .windows) {
        if (comptime @hasDecl(c, "_localtime64_s") and @hasDecl(c, "__time64_t")) {
            var t64 = std.math.cast(c.__time64_t, ts) orelse return false;
            return c._localtime64_s(out_tm, &t64) == 0;
        }
        return false;
    }

    var t = std.math.cast(c.time_t, ts) orelse return false;
    if (comptime @hasDecl(c, "localtime_r")) {
        return c.localtime_r(&t, out_tm) != null;
    }

    if (comptime @hasDecl(c, "localtime")) {
        const tm_ptr = c.localtime(&t);
        if (tm_ptr == null) return false;
        out_tm.* = tm_ptr.*;
        return true;
    }

    return false;
}

fn resetPartsAlloc(reset_at: i64, now: i64) !ResetParts {
    var tm: c.struct_tm = undefined;
    if (!localtimeCompat(reset_at, &tm)) {
        return ResetParts{
            .time = try std.fmt.allocPrint(std.heap.page_allocator, "-", .{}),
            .date = try std.fmt.allocPrint(std.heap.page_allocator, "-", .{}),
            .same_day = true,
        };
    }
    var now_tm: c.struct_tm = undefined;
    if (!localtimeCompat(now, &now_tm)) {
        return ResetParts{
            .time = try std.fmt.allocPrint(std.heap.page_allocator, "-", .{}),
            .date = try std.fmt.allocPrint(std.heap.page_allocator, "-", .{}),
            .same_day = true,
        };
    }

    const same_day = tm.tm_year == now_tm.tm_year and tm.tm_mon == now_tm.tm_mon and tm.tm_mday == now_tm.tm_mday;
    const hour = @as(u32, @intCast(tm.tm_hour));
    const min = @as(u32, @intCast(tm.tm_min));
    const day = @as(u32, @intCast(tm.tm_mday));
    const months = [_][]const u8{
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    };
    const month_idx: usize = if (tm.tm_mon < 0) 0 else @min(@as(usize, @intCast(tm.tm_mon)), months.len - 1);
    return ResetParts{
        .time = try std.fmt.allocPrint(std.heap.page_allocator, "{d:0>2}:{d:0>2}", .{ hour, min }),
        .date = try std.fmt.allocPrint(std.heap.page_allocator, "{d} {s}", .{ day, months[month_idx] }),
        .same_day = same_day,
    };
}
