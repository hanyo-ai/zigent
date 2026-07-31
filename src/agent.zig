// WikiAgent — loop + wiki architecture.
// Pure loop: user message → LLM → tools → repeat.
const std = @import("std");
const Io = std.Io;
const llm = @import("llm.zig");
const context_mod = @import("context.zig");
const tools_mod = @import("tools.zig");
const wiki_mod = @import("wiki.zig");
const esc_mod = @import("esc.zig");

pub const RunStatus = enum { ok, err };

pub const Agent = struct {
    allocator: std.mem.Allocator,
    io: Io,
    agent_name: []const u8,
    wiki_dir: []const u8,
    agent_dir: []const u8,
    sessions_dir: []const u8,
    client: llm.Client,
    ctx: context_mod.Context,
    registry: tools_mod.ToolRegistry,
    tool_ctx: tools_mod.ToolContext,
    session_id: ?[]const u8 = null,
    esc: ?*esc_mod.Watcher = null,

    pub fn init(
        allocator: std.mem.Allocator,
        io: Io,
        agent_name: []const u8,
        session_root: []const u8,
        llm_cfg: llm.Config,
        username: []const u8,
    ) !Agent {
        const agent_dir = try std.fs.path.join(allocator, &.{ session_root, ".agents", agent_name });
        try Io.Dir.createDirPath(.cwd(), io, agent_dir);

        const wiki_dir = try std.fs.path.join(allocator, &.{ agent_dir, "wiki" });
        const sessions_dir = try std.fs.path.join(allocator, &.{ agent_dir, "sessions" });

        var wiki = wiki_mod.Wiki{ .dir = wiki_dir, .io = io };
        if (!wiki.exists()) {
            try wiki.initRepl(allocator, session_root, username);
            std.debug.print("[wiki] 为 agent '{s}' 初始化了新 wiki (repl)\n", .{agent_name});
        }

        const wiki_section = try wiki.systemPromptSection(allocator);

        const today = try todayString(allocator, io);
        const system_prompt = try buildSystemPrompt(allocator, today, session_root, wiki_section);

        const cfg = llm.Config{
            .model = llm_cfg.model,
            .api_key = llm_cfg.api_key,
            .base_url = llm_cfg.base_url,
            .system_prompt = system_prompt,
            .max_tokens = llm_cfg.max_tokens,
            .thinking = llm_cfg.thinking,
        };

        return Agent{
            .allocator = allocator,
            .io = io,
            .agent_name = try allocator.dupe(u8, agent_name),
            .wiki_dir = wiki_dir,
            .agent_dir = agent_dir,
            .sessions_dir = sessions_dir,
            .client = llm.Client.init(allocator, io, cfg),
            .ctx = context_mod.Context.init(allocator),
            .registry = try tools_mod.buildCoreRegistry(allocator),
            .tool_ctx = .{ .allocator = allocator, .io = io },
        };
    }

    // ── Main loop ────────────────────────────────────────────

    /// Run one user turn through the agent loop. Returns final status.
    pub fn run(self: *Agent, user_message: []const u8) !void {
        if (user_message.len > 0) {
            try self.ctx.addUser(user_message);
        }

        var consecutive_errors: usize = 0;
        if (self.esc) |w| w.reset();

        while (true) {
            if (self.esc) |w| {
                if (w.fired()) {
                    self.ctx.rollbackOrphanedToolUse();
                    _ = self.saveSession() catch {};
                    return error.Paused;
                }
            }
            const tools_json = try self.registry.schemasJson(self.allocator);
            const messages_json = try self.ctx.toJson();

            // Streaming callbacks — print text to stdout, thinking dimmed
            var stdout_buf: [1024]u8 = undefined;
            var stdout_writer: Io.File.Writer = .init(.stdout(), self.io, &stdout_buf);

            const callbacks = llm.Callbacks{
                .ctx = &stdout_writer,
                .on_text = struct {
                    fn f(c: ?*anyopaque, text: []const u8) void {
                        const sw: *Io.File.Writer = @ptrCast(@alignCast(c.?));
                        sw.interface.writeAll(text) catch {};
                        sw.interface.flush() catch {};
                    }
                }.f,
                .on_thinking = struct {
                    fn f(c: ?*anyopaque, text: []const u8) void {
                        const sw: *Io.File.Writer = @ptrCast(@alignCast(c.?));
                        sw.interface.writeAll("\x1b[2m") catch {};
                        sw.interface.writeAll(text) catch {};
                        sw.interface.writeAll("\x1b[0m") catch {};
                        sw.interface.flush() catch {};
                    }
                }.f,
            };

            const response = self.client.create(messages_json, tools_json, callbacks) catch |err| {
                consecutive_errors += 1;
                std.debug.print("\n[LLM error #{d}]: {s}\n", .{ consecutive_errors, @errorName(err) });
                if (consecutive_errors >= 3) {
                    std.debug.print("Error: too many consecutive LLM failures\n", .{});
                    return;
                }
                const delay_s: i64 = @intCast(@min(std.math.shl(u64, 1, consecutive_errors), 30));
                Io.sleep(self.io, .fromSeconds(delay_s), .awake) catch {};
                continue;
            };
            consecutive_errors = 0;

            // Convert to context blocks, drop tool_use without input
            var asst_blocks: std.ArrayList(context_mod.Block) = .empty;
            var tool_use_count: usize = 0;
            for (response.blocks.items) |b| {
                switch (b.block_type) {
                    .text => {
                        if (b.text.len > 0) {
                            try asst_blocks.append(self.allocator, .{
                                .block_type = .text,
                                .text = b.text,
                            });
                        }
                    },
                    .tool_use => {
                        tool_use_count += 1;
                        try asst_blocks.append(self.allocator, .{
                            .block_type = .tool_use,
                            .id = b.id,
                            .name = b.name,
                            .input_json = b.input_json,
                        });
                    },
                }
            }
            try self.ctx.addAssistant(asst_blocks);

            if (tool_use_count == 0) {
                break;
            }

            // Execute tools
            var results: std.ArrayList(context_mod.Block) = .empty;
            for (response.blocks.items) |b| {
                if (b.block_type != .tool_use) continue;

                if (self.esc) |w| {
                    if (w.fired()) {
                        try results.append(self.allocator, .{
                            .block_type = .tool_result,
                            .id = b.id,
                            .text = "[interrupted: user pressed ESC]",
                            .is_error = true,
                        });
                        continue;
                    }
                }

                std.debug.print("\n[tool: {s}] ", .{b.name});

                const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, b.input_json, .{}) catch {
                    try results.append(self.allocator, .{
                        .block_type = .tool_result,
                        .id = b.id,
                        .text = "Error: invalid tool input JSON",
                        .is_error = true,
                    });
                    continue;
                };
                defer parsed.deinit();

                const output = try self.registry.dispatch(&self.tool_ctx, b.name, parsed.value);
                std.debug.print("\x1b[90m{s}\x1b[0m\n", .{output});

                try results.append(self.allocator, .{
                    .block_type = .tool_result,
                    .id = b.id,
                    .text = output,
                    .is_error = false,
                });
            }

            try self.ctx.addToolResults(results.items);
        }

        try self.saveSession();
    }

    // ── Session persistence ──────────────────────────────────

    pub fn saveSession(self: *Agent) !void {
        try Io.Dir.createDirPath(.cwd(), self.io, self.sessions_dir);

        if (self.session_id == null) {
            const ts = Io.Timestamp.now(self.io, .real).toSeconds();
            self.session_id = try std.fmt.allocPrint(self.allocator, "session_{d}", .{ts});
        }

        const file_path = try std.fs.path.join(self.allocator, &.{ self.sessions_dir, self.session_id.? });

        // Serialize messages to JSON
        const json = try self.ctx.toJson();
        var buf: std.Io.Writer.Allocating = .init(self.allocator);
        const w = &buf.writer;
        try w.print("{{\n  \"session_id\": ", .{});
        try context_mod.writeJsonString(w, self.session_id.?);
        try w.print(",\n  \"agent_name\": ", .{});
        try context_mod.writeJsonString(w, self.agent_name);
        try w.print(",\n  \"messages\": {s}\n}}", .{json});

        try Io.Dir.writeFile(.cwd(), self.io, .{ .sub_path = file_path, .data = buf.writer.buffered() });
    }
};

fn todayString(allocator: std.mem.Allocator, io: Io) ![]u8 {
    const epoch_secs: u64 = @intCast(Io.Timestamp.now(io, .real).toSeconds());
    var days: i64 = @intCast(epoch_secs / 86400);
    var year: i64 = 1970;
    while (true) {
        const diy: i64 = if (isLeapYear(year)) 366 else 365;
        if (days < diy) break;
        days -= diy;
        year += 1;
    }
    const month_days = if (isLeapYear(year))
        [_]i64{ 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    else
        [_]i64{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var month: i64 = 1;
    for (month_days) |md| {
        if (days < md) break;
        days -= md;
        month += 1;
    }
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}", .{ year, month, days + 1 });
}

fn isLeapYear(year: i64) bool {
    return (@mod(year, 4) == 0 and @mod(year, 100) != 0) or (@mod(year, 400) == 0);
}

fn buildSystemPrompt(allocator: std.mem.Allocator, date: []const u8, session_root: []const u8, wiki_section: []const u8) ![]u8 {
    const template =
        \\Current date: {DATE}
        \\Current session path: {SESSION_ROOT}
        \\
        \\You are the REPL assistant for the taus agent framework.
        \\You have shell and file tools — no persistent memory or skill system.
        \\
        \\## Tools
        \\{TOOLS}
        \\
        \\## Image Display
        \\
        \\When you read an image (png/jpg/gif/webp), `read` returns a path — not raw data.
        \\Embed images with markdown, using the absolute path:
        \\
        \\    ![description](http://127.0.0.1:8000/api/files?path=/absolute/path/to/image.png)
        \\
        \\New images default to `./temp/`. Use timestamps: `./temp/screenshot-20260725_153020.png`.
        \\Never use fixed names like `screenshot.png` — they get overwritten.
        \\
        \\Your wiki contains your identity, environment info, and advanced capabilities (multi-agent communication, etc.).
        \\Read from it when needed; do not write to it unless asked.
        \\
        \\{WIKI}
    ;

    var tools_section: std.Io.Writer.Allocating = .init(allocator);
    const tw = &tools_section.writer;
    try tw.writeAll("You have the following tools:\n");
    for (tools_mod.TOOL_LABELS) |tl| {
        try tw.print("- `{s}` — {s}\n", .{ tl.name, tl.label });
    }

    var buf: std.Io.Writer.Allocating = .init(allocator);
    const w = &buf.writer;

    var remaining: []const u8 = template;
    while (remaining.len > 0) {
        if (replaceOnce(&remaining, "{DATE}", date)) |s| {
            try w.writeAll(s);
        } else if (replaceOnce(&remaining, "{SESSION_ROOT}", session_root)) |s| {
            try w.writeAll(s);
        } else if (replaceOnce(&remaining, "{TOOLS}", tools_section.writer.buffered())) |s| {
            try w.writeAll(s);
        } else if (replaceOnce(&remaining, "{WIKI}", wiki_section)) |s| {
            try w.writeAll(s);
        } else {
            try w.writeByte(remaining[0]);
            remaining = remaining[1..];
        }
    }

    var _list = buf.toArrayList();
        return _list.toOwnedSlice(allocator);
}

fn replaceOnce(remaining: *[]const u8, placeholder: []const u8, value: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, remaining.*, placeholder)) {
        remaining.* = remaining.*[placeholder.len..];
        return value;
    }
    return null;
}
