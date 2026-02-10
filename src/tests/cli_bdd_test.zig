const std = @import("std");
const cli = @import("../cli.zig");

fn isHelp(cmd: cli.Command) bool {
    return switch (cmd) {
        .help => true,
        else => false,
    };
}

test "Scenario: Given add with no-login when parsing then login flow is disabled" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "add", "--no-login" };
    var cmd = try cli.parseArgs(gpa, &args);
    defer cli.freeCommand(gpa, &cmd);

    switch (cmd) {
        .add => |opts| try std.testing.expect(!opts.login),
        else => return error.TestExpectedEqual,
    }
}

test "Scenario: Given import path and name when parsing then import options are preserved" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "import", "/tmp/auth.json", "--name", "personal" };
    var cmd = try cli.parseArgs(gpa, &args);
    defer cli.freeCommand(gpa, &cmd);

    switch (cmd) {
        .import_auth => |opts| {
            try std.testing.expect(std.mem.eql(u8, opts.auth_path, "/tmp/auth.json"));
            try std.testing.expect(opts.name != null);
            try std.testing.expect(std.mem.eql(u8, opts.name.?, "personal"));
        },
        else => return error.TestExpectedEqual,
    }
}

test "Scenario: Given list with extra args when parsing then help command is returned" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "list", "unexpected" };
    var cmd = try cli.parseArgs(gpa, &args);
    defer cli.freeCommand(gpa, &cmd);

    try std.testing.expect(isHelp(cmd));
}

test "Scenario: Given add with unknown flag when parsing then help command is returned" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "add", "--bad-flag" };
    var cmd = try cli.parseArgs(gpa, &args);
    defer cli.freeCommand(gpa, &cmd);

    try std.testing.expect(isHelp(cmd));
}
