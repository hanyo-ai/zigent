// zigent — loop + wiki agent framework, Zig port of taus (REPL mode only).
const std = @import("std");
const Io = std.Io;
const config_mod = @import("config.zig");
const agent_mod = @import("agent.zig");
const esc_mod = @import("esc.zig");
const lineedit = @import("lineedit.zig");
const llm_mod = @import("llm.zig");

pub fn main(init: std.process.Init) !void {
    installSigintHandler();

    const allocator = init.arena.allocator();
    const io = init.io;

    // ── Setup stdout/stdin ──
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out = &stdout_writer.interface;

    // ── Load config ──
    const cfg = try config_mod.load(allocator, io, init.environ_map);

    // ── Session root (CWD) ──
    var cwd_buf: [4096]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    const session_root = cwd_buf[0..cwd_len];

    const username = init.environ_map.get("USER") orelse "user";

    // ── ESC watcher (cooperative pause at loop detection points) ──
    var watcher = esc_mod.Watcher.init(io);
    var group: Io.Group = .init;
    defer group.cancel(io);
    global_watcher = &watcher;
    defer global_watcher = null;

    // ── Banner ──
    try out.print("[zigent] REPL 模式 | Model: {s} | Provider: {s}\n", .{ cfg.model, cfg.provider });
    try out.print("[zigent] Session root: {s}\n", .{session_root});
    try out.print("输入消息开始，/help 查看命令，Ctrl+D 退出\n\n", .{});
    try out.flush();

    // ── Initialize agent ──
    var agent = try agent_mod.Agent.init(
        allocator,
        io,
        "repl",
        session_root,
        .{
            .model = cfg.model,
            .api_key = cfg.api_key,
            .base_url = cfg.base_url,
            .system_prompt = "",
            .thinking = cfg.thinking,
        },
        username,
    );

    // ── REPL loop ──
    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader: Io.File.Reader = .init(.stdin(), io, &stdin_buf);
    const input_reader = &stdin_reader.interface;

    var editor = lineedit.Editor.init(allocator);
    const stdin_is_tty = isTty();

    var paused = false;
    var last_input: []const u8 = "";

    while (true) {
        // Bottom status line: context usage + model + hints.
        try writeToolbar(out, &agent, cfg.model);

        var input: []const u8 = "";
        if (stdin_is_tty) {
            // Raw-mode line editor: "/" shows live command completions,
            // Tab completes, ↑/↓ history. Returns "" on Ctrl+C.
            const line_opt = editor.readLine("\x1b[32m>\x1b[0m ", 2) catch |err| switch (err) {
                error.NoTty => null, // fall through to canonical read
                else => return err,
            };
            if (line_opt) |line| {
                input = std.mem.trim(u8, line, " \t\r\n");
            } else {
                // Ctrl+D on empty line
                try out.writeAll("\nBye!\n");
                try out.flush();
                return;
            }
            if (input.len == 0) continue;
        } else {
            try out.writeAll("\x1b[32m>\x1b[0m ");
            try out.flush();

            const line = input_reader.takeDelimiterInclusive('\n') catch |err| switch (err) {
                error.EndOfStream => {
                    try out.writeAll("\nBye!\n");
                    try out.flush();
                    return;
                },
                error.StreamTooLong => {
                    try out.writeAll("[zigent] 输入过长\n");
                    try out.flush();
                    continue;
                },
                error.ReadFailed => return stdin_reader.err.?,
            };

            input = std.mem.trim(u8, line, " \t\r\n");
            if (input.len == 0) continue;
        }

        if (paused) {
            // After ESC: /go re-runs, /abort drops, anything else = 纠偏注入.
            if (eq(input, "/go")) {
                paused = false;
                try out.writeAll("\n▶️  继续。\n\n");
                try out.flush();
            } else if (eq(input, "/abort")) {
                paused = false;
                last_input = "";
                try out.writeAll("\n🛑 已中止。\n");
                try out.flush();
                continue;
            } else {
                paused = false;
                last_input = try std.fmt.allocPrint(allocator, "{s}\n\n[用户纠偏]: {s}", .{ last_input, input });
                try out.writeAll("\n💬 纠偏注入。\n\n");
                try out.flush();
            }
        } else {
            // Slash commands
            if (input[0] == '/') {
                const action = try handleCommand(out, input, &agent, cfg);
                switch (action) {
                    .quit => {
                        try out.writeAll("\nBye!\n");
                        try out.flush();
                        return;
                    },
                    .ok => continue,
                }
            }

            try out.writeAll("\n");
            try out.flush();
            last_input = try allocator.dupe(u8, input);
        }

        // Run agent turn (ESC watcher active during the run).
        watcher.start(&group);
        watcher.reset();
        agent.esc = &watcher;
        const run_result = agent.run(last_input);
        watcher.stop();
        agent.esc = null;

        if (run_result) |_| {
            paused = false;
        } else |err| switch (err) {
            error.Paused => {
                paused = true;
                try out.writeAll("\n⏸️  已暂停。/go 继续，/abort 中止，或直接输入纠偏内容。\n");
            },
            else => {
                try out.print("\n✗ Error: {s}\n", .{@errorName(err)});
            },
        }

        try out.writeAll("\n");
        try out.flush();
    }
}

// ── Ctrl+C (SIGINT) — same semantics as ESC: cooperative pause. ──

var global_watcher: ?*esc_mod.Watcher = null;

fn onSigint(_: @TypeOf(std.posix.SIG.INT)) callconv(.c) void {
    if (global_watcher) |w| w.fire();
}

fn installSigintHandler() void {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return;
    const act = std.posix.Sigaction{
        .handler = .{ .handler = onSigint },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
}

// ── Bottom status line (like taus' prompt_toolkit bottom toolbar) ──

const CONTEXT_WINDOW: usize = 1_000_000;

fn writeToolbar(out: *Io.Writer, agent: *agent_mod.Agent, model: []const u8) !void {
    const u = &agent.client.usage;
    const used = u.lastContextTokens() + agent.client.config.system_prompt.len / 3;
    const pct: f64 = @as(f64, @floatFromInt(used)) / @as(f64, @floatFromInt(CONTEXT_WINDOW)) * 100.0;

    const color: []const u8 = if (pct <= 40) "32" else if (pct <= 60) "33" else "31";

    // "\x1b7" saves the cursor; the line is drawn below the prompt row and
    // erased on the next repaint — it stays pinned at the bottom of output.
    try out.print(
        "\x1b7\n\x1b[2K\x1b[48;5;236m\x1b[{s}m ctx {d:.1}% · ~{d}/{d} tok \x1b[38;5;245m  {s} | esc 暂停 · /help \x1b[0m\x1b8\n",
        .{ color, pct, used, CONTEXT_WINDOW, model },
    );
}

const Action = enum { ok, quit };

fn isTty() bool {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return false;
    return std.c.isatty(std.posix.STDIN_FILENO) == 1;
}

fn handleCommand(out: *Io.Writer, raw: []const u8, agent: *agent_mod.Agent, cfg: config_mod.Config) !Action {
    var it = std.mem.splitScalar(u8, raw, ' ');
    const cmd = it.first();

    if (eq(cmd, "/help") or eq(cmd, "/h") or eq(cmd, "/?")) {
        try out.writeAll(
            \\
            \\可用命令:
            \\  /help, /h, /?              显示帮助
            \\  /exit, /q, /quit           退出
            \\  /clear, /reset             清屏
            \\  /model                     显示当前模型配置
            \\  /usage                     上下文窗口用量明细
            \\  ESC/Ctrl+C                 暂停（运行中）
            \\  /go /abort                 继续 / 中止
            \\
        );
        return .ok;
    }

    if (eq(cmd, "/exit") or eq(cmd, "/q") or eq(cmd, "/quit")) {
        return .quit;
    }

    if (eq(cmd, "/clear") or eq(cmd, "/reset")) {
        try out.writeAll("\x1b[2J\x1b[H");
        return .ok;
    }

    if (eq(cmd, "/model")) {
        try out.print("\n模型: {s} | provider: {s} | thinking: {s}\n", .{
            cfg.model, cfg.provider, if (cfg.thinking) "开启" else "关闭",
        });
        return .ok;
    }

    if (eq(cmd, "/usage")) {
        const u = &agent.client.usage;
        const used = u.lastContextTokens() + agent.client.config.system_prompt.len / 3;
        const pct: f64 = @as(f64, @floatFromInt(used)) / @as(f64, @floatFromInt(CONTEXT_WINDOW)) * 100.0;
        const color: []const u8 = if (pct <= 40) "32" else if (pct <= 60) "33" else "31";
        try out.print("\n上下文窗口: \x1b[{s}m[ctx] {d:.1}% · ~{d} / {d} tokens\x1b[0m\n", .{ color, pct, used, CONTEXT_WINDOW });
        try out.print("  最近请求输入: {d} tok (cache 读: {d} / 写: {d})\n", .{ u.input_tokens, u.cache_read_input_tokens, u.cache_creation_input_tokens });
        try out.print("  会话累计输出: {d} tok\n", .{u.output_tokens});
        try out.print("  窗口: {d} tok | 阈值: ≤40% 绿 · 40–60% 黄 · >60% 红\n\n", .{CONTEXT_WINDOW});
        return .ok;
    }

    try out.print("\n未知命令: {s}（/help 查看帮助）\n", .{cmd});
    return .ok;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
