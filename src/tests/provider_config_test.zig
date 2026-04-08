const std = @import("std");
const provider_config = @import("../provider_config.zig");

test "Scenario: Given config without managed block when activating provider then managed block is appended" {
    const gpa = std.testing.allocator;
    const before =
        \\model = "gpt-5.4"
        \\
        \\[plugins."github@openai-curated"]
        \\enabled = true
    ;

    const after = try provider_config.renderManagedProviderConfig(gpa, before, .{
        .provider_id = "openrouter",
        .base_url = "https://openrouter.ai/api/v1",
        .api_key = "sk-test",
        .wire_api = "responses",
        .model = null,
    });
    defer gpa.free(after);

    try std.testing.expect(std.mem.indexOf(u8, after, provider_config.managed_begin) != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "model_provider = \"openrouter\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "[plugins.\"github@openai-curated\"]") != null);
}

test "Scenario: Given config with managed block when activating provider then previous block is replaced" {
    const gpa = std.testing.allocator;
    const before =
        \\model = "gpt-5.4"
        \\
        \\# BEGIN codex-auth managed provider
        \\model_provider = "old"
        \\
        \\[model_providers.old]
        \\base_url = "https://old.example.com"
        \\api_key = "sk-old"
        \\wire_api = "responses"
        \\# END codex-auth managed provider
        \\
        \\[tui]
        \\show_tooltips = true
    ;

    const after = try provider_config.renderManagedProviderConfig(gpa, before, .{
        .provider_id = "openrouter",
        .base_url = "https://openrouter.ai/api/v1",
        .api_key = "sk-test",
        .wire_api = "responses",
        .model = "gpt-5.4",
    });
    defer gpa.free(after);

    try std.testing.expect(std.mem.indexOf(u8, after, "[model_providers.old]") == null);
    try std.testing.expect(std.mem.indexOf(u8, after, "[model_providers.\"openrouter\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "model = \"gpt-5.4\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "[tui]") != null);
}

test "Scenario: Given config with managed block when clearing provider then block is removed and unrelated config is preserved" {
    const gpa = std.testing.allocator;
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

    const after = try provider_config.clearManagedProviderConfig(gpa, before);
    defer gpa.free(after);

    try std.testing.expect(std.mem.indexOf(u8, after, provider_config.managed_begin) == null);
    try std.testing.expect(std.mem.indexOf(u8, after, "model_provider = \"openrouter\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, after, "model = \"gpt-5.4\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "[tui]") != null);
}

test "Scenario: Given config file when applying and clearing provider then config.toml is updated in place" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.writeFile(.{
        .sub_path = "config.toml",
        .data =
        \\model = "gpt-5.4"
        \\
        \\[tui]
        \\show_tooltips = true
        ,
    });

    try provider_config.applyManagedProviderProfile(gpa, codex_home, .{
        .provider_id = "openrouter",
        .base_url = "https://openrouter.ai/api/v1",
        .api_key = "sk-test",
        .wire_api = "responses",
        .model = null,
    });

    const config_path = try std.fs.path.join(gpa, &[_][]const u8{ codex_home, "config.toml" });
    defer gpa.free(config_path);
    const applied = try std.fs.cwd().readFileAlloc(gpa, config_path, 10 * 1024 * 1024);
    defer gpa.free(applied);
    try std.testing.expect(std.mem.indexOf(u8, applied, "[model_providers.\"openrouter\"]") != null);

    try provider_config.clearManagedProviderProfile(gpa, codex_home);

    const cleared = try std.fs.cwd().readFileAlloc(gpa, config_path, 10 * 1024 * 1024);
    defer gpa.free(cleared);
    try std.testing.expect(std.mem.indexOf(u8, cleared, provider_config.managed_begin) == null);
    try std.testing.expect(std.mem.indexOf(u8, cleared, "[tui]") != null);
}
