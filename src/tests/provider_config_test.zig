const std = @import("std");
const provider_config = @import("../provider_config.zig");

test "Scenario: Given config text when scanning providers then ids names and active provider are discovered" {
    const gpa = std.testing.allocator;
    const config =
        \\model_provider = "codexshare"
        \\disable_response_storage = true
        \\preferred_auth_method = "apikey"
        \\
        \\[model_providers.codexshare]
        \\name = "codexshare"
        \\base_url = "https://www.codexshare.cloud/v1"
        \\wire_api = "responses"
        \\experimental_bearer_token = "dummy"
        \\
        \\[model_providers.openrouter]
        \\name = "OpenRouter"
        \\base_url = "https://openrouter.ai/api/v1"
        \\wire_api = "responses"
    ;

    var scan = try provider_config.scanProvidersFromText(gpa, config);
    defer scan.deinit(gpa);

    try std.testing.expectEqualStrings("codexshare", scan.active_provider_id.?);
    try std.testing.expectEqual(@as(usize, 2), scan.providers.items.len);
    try std.testing.expectEqualStrings("codexshare", scan.providers.items[0].provider_id);
    try std.testing.expectEqualStrings("codexshare", scan.providers.items[0].label);
    try std.testing.expectEqualStrings("dummy", scan.providers.items[0].auth_token.?);
    try std.testing.expectEqualStrings("OpenRouter", scan.providers.items[1].label);
}

test "Scenario: Given config file when selecting provider then model provider and auth mode are enabled in place" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.writeFile(.{
        .sub_path = "config.toml",
        .data =
        \\# model_provider = "openai"
        \\disable_response_storage = true
        \\# preferred_auth_method = "chatgpt"
        \\
        \\model = "gpt-5.4"
        \\model_reasoning_effort = "high"
        \\
        \\[model_providers.codexshare]
        \\name = "codexshare"
        \\base_url = "https://www.codexshare.cloud/v1"
        \\wire_api = "responses"
        \\experimental_bearer_token = "dummy"
        ,
    });

    try provider_config.applyProviderSelection(gpa, codex_home, "codexshare");

    const config_path = try std.fs.path.join(gpa, &[_][]const u8{ codex_home, "config.toml" });
    defer gpa.free(config_path);
    const applied = try std.fs.cwd().readFileAlloc(gpa, config_path, 10 * 1024 * 1024);
    defer gpa.free(applied);

    try std.testing.expect(std.mem.startsWith(u8, applied, "model_provider = \"codexshare\"\ndisable_response_storage = true\npreferred_auth_method = \"apikey\"\n"));
    try std.testing.expect(std.mem.indexOf(u8, applied, "[model_providers.codexshare]") != null);
}

test "Scenario: Given provider-active config when clearing selection then provider lines are commented and provider blocks remain" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.writeFile(.{
        .sub_path = "config.toml",
        .data =
        \\model_provider = "codexshare"
        \\disable_response_storage = true
        \\preferred_auth_method = "apikey"
        \\
        \\model = "gpt-5.4"
        \\
        \\[model_providers.codexshare]
        \\name = "codexshare"
        \\base_url = "https://www.codexshare.cloud/v1"
        \\wire_api = "responses"
        \\experimental_bearer_token = "dummy"
        ,
    });

    try provider_config.clearProviderSelection(gpa, codex_home);

    const config_path = try std.fs.path.join(gpa, &[_][]const u8{ codex_home, "config.toml" });
    defer gpa.free(config_path);
    const cleared = try std.fs.cwd().readFileAlloc(gpa, config_path, 10 * 1024 * 1024);
    defer gpa.free(cleared);

    try std.testing.expect(std.mem.startsWith(u8, cleared, "# model_provider = \"codexshare\"\ndisable_response_storage = true\n# preferred_auth_method = \"apikey\"\n"));
    try std.testing.expect(std.mem.indexOf(u8, cleared, "[model_providers.codexshare]") != null);
}
