// Environment configuration — loads .env files and env vars.
// Resolution order: ~/.taus/.env first, then CWD .env (overrides), then process env.
const std = @import("std");
const Io = std.Io;

pub const Config = struct {
    model: []const u8 = "claude-sonnet-4-6",
    api_key: []const u8 = "",
    base_url: []const u8 = "",
    provider: []const u8 = "anthropic",
    thinking: bool = false,
};

/// Load config from env vars + .env files.
/// Resolution: ~/.taus/.env → CWD .env → process env vars (last wins).
pub fn load(allocator: std.mem.Allocator, io: Io, environ_map: *const std.process.Environ.Map) !Config {
    var cfg = Config{};

    // Try loading ~/.taus/.env
    if (environ_map.get("HOME")) |home| {
        const global_env_path = try std.fs.path.join(allocator, &.{ home, ".taus", ".env" });
        defer allocator.free(global_env_path);
        applyEnvFile(allocator, io, global_env_path, &cfg);
    }

    // Try loading CWD .env (overrides global)
    applyEnvFile(allocator, io, ".env", &cfg);

    // Process env vars override everything
    if (environ_map.get("MODEL")) |v| cfg.model = try allocator.dupe(u8, v);
    if (environ_map.get("API_KEY")) |v| cfg.api_key = try allocator.dupe(u8, v);
    if (environ_map.get("BASE_URL")) |v| cfg.base_url = try allocator.dupe(u8, v);
    if (environ_map.get("PROVIDER")) |v| cfg.provider = try allocator.dupe(u8, v);
    if (environ_map.get("THINKING")) |v| {
        cfg.thinking = std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true");
    }

    return cfg;
}

/// Parse a .env file and apply values. Silently ignores missing file.
fn applyEnvFile(allocator: std.mem.Allocator, io: Io, path: []const u8, cfg: *Config) void {
    var buf: [8192]u8 = undefined;
    const content = Io.Dir.readFile(.cwd(), io, path, &buf) catch return;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const key = trimmed[0..eq];
        const value = trimmed[eq + 1 ..];

        if (std.mem.eql(u8, key, "MODEL")) {
            cfg.model = allocator.dupe(u8, value) catch cfg.model;
        } else if (std.mem.eql(u8, key, "API_KEY")) {
            cfg.api_key = allocator.dupe(u8, value) catch cfg.api_key;
        } else if (std.mem.eql(u8, key, "BASE_URL")) {
            cfg.base_url = allocator.dupe(u8, value) catch cfg.base_url;
        } else if (std.mem.eql(u8, key, "PROVIDER")) {
            cfg.provider = allocator.dupe(u8, value) catch cfg.provider;
        } else if (std.mem.eql(u8, key, "THINKING")) {
            cfg.thinking = std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "true");
        }
    }
}
