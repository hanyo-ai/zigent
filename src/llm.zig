// LLM Client — Anthropic-compatible API with SSE streaming.
const std = @import("std");
const Io = std.Io;

pub const Usage = struct {
    input_tokens: usize = 0,
    output_tokens: usize = 0,
    cache_creation_input_tokens: usize = 0,
    cache_read_input_tokens: usize = 0,

    pub fn lastContextTokens(self: *const Usage) usize {
        return self.input_tokens + self.cache_read_input_tokens + self.cache_creation_input_tokens;
    }
};

pub const BlockType = enum { text, tool_use };

pub const LlmBlock = struct {
    block_type: BlockType,
    text: []const u8 = "", // accumulated text (for text blocks)
    id: []const u8 = "", // tool_use id
    name: []const u8 = "", // tool_use name
    input_json: []const u8 = "", // tool_use input (raw JSON)
};

pub const LlmResponse = struct {
    blocks: std.ArrayList(LlmBlock) = .empty,
    stop_reason: []const u8 = "",
};

pub const Callbacks = struct {
    on_text: *const fn (ctx: ?*anyopaque, text: []const u8) void,
    on_thinking: *const fn (ctx: ?*anyopaque, text: []const u8) void,
    ctx: ?*anyopaque = null,
};

pub const Config = struct {
    model: []const u8,
    api_key: []const u8,
    base_url: []const u8,
    system_prompt: []const u8,
    max_tokens: u32 = 16384,
    thinking: bool = false,
};

pub const Client = struct {
    config: Config,
    usage: Usage = .{},
    allocator: std.mem.Allocator,
    io: Io,

    pub fn init(allocator: std.mem.Allocator, io: Io, cfg: Config) Client {
        return .{ .config = cfg, .allocator = allocator, .io = io };
    }

    /// Create a streaming completion. Returns structured response blocks.
    pub fn create(
        self: *Client,
        messages_json: []const u8,
        tools_json: ?[]const u8,
        callbacks: Callbacks,
    ) !LlmResponse {
        const allocator = self.allocator;

        // ── Build request body ──
        var body: std.Io.Writer.Allocating = .init(allocator);
        const w = &body.writer;

        try w.print("{{\"model\":", .{});
        try jsonStr(w, self.config.model);
        try w.print(",\"max_tokens\":{d},\"stream\":true", .{self.config.max_tokens});

        try w.writeAll(",\"system\":");
        try jsonStr(w, self.config.system_prompt);

        try w.writeAll(",\"messages\":");
        try w.writeAll(messages_json);

        if (self.config.thinking) {
            try w.writeAll(",\"thinking\":{\"type\":\"adaptive\"}");
        }

        if (tools_json) |tj| {
            try w.writeAll(",\"tools\":");
            try w.writeAll(tj);
        }

        try w.writeByte('}');

        const payload = body.writer.buffered();

        // ── Build URL ──
        var base = self.config.base_url;
        if (base.len == 0) base = "https://api.anthropic.com";
        while (base.len > 0 and base[base.len - 1] == '/') base = base[0 .. base.len - 1];
        if (std.mem.endsWith(u8, base, "/v1")) base = base[0 .. base.len - 3];

        const url = try std.fmt.allocPrint(allocator, "{s}/v1/messages", .{base});
        const uri = try std.Uri.parse(url);

        // ── HTTP request ──
        var http_client: std.http.Client = .{
            .allocator = allocator,
            .io = self.io,
        };
        defer http_client.deinit();

        const extra_headers = [_]std.http.Header{
            .{ .name = "anthropic-version", .value = "2023-06-01" },
            .{ .name = "x-api-key", .value = self.config.api_key },
        };

        var req = try std.http.Client.request(&http_client, .POST, uri, .{
            .keep_alive = false,
            .redirect_behavior = .not_allowed,
            .headers = .{ .content_type = .{ .override = "application/json" } },
            .extra_headers = &extra_headers,
        });
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = payload.len };
        var body_buf: [4096]u8 = undefined;
        var bw = try req.sendBodyUnflushed(&body_buf);
        try bw.writer.writeAll(payload);
        try bw.end();
        try req.connection.?.flush();

        var redirect_buf: [1024]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);

        if (response.head.status != .ok) {
            const reader = response.reader(&.{});
            const err_body = reader.allocRemaining(allocator, .limited(64 * 1024)) catch "";
            std.debug.print("[LLM] HTTP {d}: {s}\n", .{ @intFromEnum(response.head.status), err_body });
            return error.ApiError;
        }

        // ── Parse SSE stream (large buffer: individual data lines can be long) ──
        const transfer_buf = try allocator.alloc(u8, 256 * 1024);
        defer allocator.free(transfer_buf);
        const reader = response.reader(transfer_buf);

        return self.parseSse(reader, callbacks);
    }

    fn parseSse(self: *Client, reader: *std.Io.Reader, callbacks: Callbacks) !LlmResponse {
        const allocator = self.allocator;

        var result = LlmResponse{};

        // Current accumulating state
        var current_text: std.ArrayList(u8) = .empty;
        var current_tool_id: std.ArrayList(u8) = .empty;
        var current_tool_name: std.ArrayList(u8) = .empty;
        var current_tool_input: std.ArrayList(u8) = .empty;
        var in_tool_use = false;
        var in_thinking = false;
        var current_index: usize = 0;
        var saw_text_delta = false;

        var raw_count: usize = 0;
        while (true) {
            const line = reader.takeDelimiterInclusive('\n') catch |err| switch (err) {
                error.EndOfStream => {
                    // process any remaining buffered data below
                    break;
                },
                error.ReadFailed => return error.StreamReadFailed,
                error.StreamTooLong => return error.LineTooLong,
            };
            raw_count += 1;

            const trimmed = std.mem.trimEnd(u8, line, "\r\n");

            if (trimmed.len == 0) continue;

            if (!std.mem.startsWith(u8, trimmed, "data:")) continue;
            var data = trimmed["data:".len..];
            if (data.len > 0 and data[0] == ' ') data = data[1..];

            const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch {
                continue;
            };
            defer parsed.deinit();
            const obj = parsed.value;
            if (obj != .object) continue;

            const type_val = obj.object.get("type") orelse continue;
            if (type_val != .string) continue;
            const etype = type_val.string;

            if (std.mem.eql(u8, etype, "content_block_start")) {
                const cb = obj.object.get("content_block") orelse continue;
                if (cb != .object) continue;
                const idx_val = obj.object.get("index");
                if (idx_val) |v| {
                    if (v == .integer) current_index = @intCast(v.integer);
                }

                const bt = cb.object.get("type") orelse continue;
                if (bt != .string) continue;

                if (std.mem.eql(u8, bt.string, "text")) {
                    in_tool_use = false;
                    saw_text_delta = false;
                    current_text.clearRetainingCapacity();
                } else if (std.mem.eql(u8, bt.string, "tool_use")) {
                    in_tool_use = true;
                    current_tool_id.clearRetainingCapacity();
                    current_tool_name.clearRetainingCapacity();
                    current_tool_input.clearRetainingCapacity();
                    if (cb.object.get("id")) |id| {
                        if (id == .string) try current_tool_id.appendSlice(allocator, id.string);
                    }
                    if (cb.object.get("name")) |name| {
                        if (name == .string) try current_tool_name.appendSlice(allocator, name.string);
                    }
                } else if (std.mem.eql(u8, bt.string, "thinking")) {
                    in_thinking = true;
                }
            } else if (std.mem.eql(u8, etype, "content_block_delta")) {
                const delta = obj.object.get("delta") orelse continue;
                if (delta != .object) continue;
                const dt = delta.object.get("type") orelse continue;
                if (dt != .string) continue;

                if (std.mem.eql(u8, dt.string, "text_delta")) {
                    const txt = delta.object.get("text") orelse continue;
                    if (txt != .string) continue;
                    try current_text.appendSlice(allocator, txt.string);
                    saw_text_delta = true;
                    callbacks.on_text(callbacks.ctx, txt.string);
                } else if (std.mem.eql(u8, dt.string, "thinking_delta")) {
                    const th = delta.object.get("thinking") orelse continue;
                    if (th != .string) continue;
                    callbacks.on_thinking(callbacks.ctx, th.string);
                } else if (std.mem.eql(u8, dt.string, "input_json_delta")) {
                    const partial = delta.object.get("partial_json") orelse continue;
                    if (partial != .string) continue;
                    try current_tool_input.appendSlice(allocator, partial.string);
                }
            } else if (std.mem.eql(u8, etype, "content_block_stop")) {
                if (in_thinking) {
                    in_thinking = false;
                } else if (in_tool_use) {
                    try result.blocks.append(allocator, .{
                        .block_type = .tool_use,
                        .id = try allocator.dupe(u8, current_tool_id.items),
                        .name = try allocator.dupe(u8, current_tool_name.items),
                        .input_json = try allocator.dupe(u8, current_tool_input.items),
                    });
                    in_tool_use = false;
                } else {
                    if (current_text.items.len > 0) {
                        try result.blocks.append(allocator, .{
                            .block_type = .text,
                            .text = try allocator.dupe(u8, current_text.items),
                        });
                        current_text.clearRetainingCapacity();
                    }
                }
            } else if (std.mem.eql(u8, etype, "message_delta")) {
                const delta = obj.object.get("delta");
                if (delta) |d| {
                    if (d == .object) {
                        if (d.object.get("stop_reason")) |sr| {
                            if (sr == .string) result.stop_reason = try allocator.dupe(u8, sr.string);
                        }
                    }
                }
                if (obj.object.get("usage")) |u| {
                    if (u == .object) {
                        if (u.object.get("output_tokens")) |ot| {
                            if (ot == .integer) self.usage.output_tokens += @intCast(ot.integer);
                        }
                    }
                }
            } else if (std.mem.eql(u8, etype, "message_start")) {
                const msg = obj.object.get("message");
                if (msg) |m| {
                    if (m == .object) {
                        if (m.object.get("usage")) |u| {
                            if (u == .object) {
                                if (u.object.get("input_tokens")) |it| {
                                    if (it == .integer) self.usage.input_tokens = @intCast(it.integer);
                                }
                                if (u.object.get("cache_creation_input_tokens")) |c| {
                                    if (c == .integer) self.usage.cache_creation_input_tokens = @intCast(c.integer);
                                }
                                if (u.object.get("cache_read_input_tokens")) |c| {
                                    if (c == .integer) self.usage.cache_read_input_tokens = @intCast(c.integer);
                                }
                            }
                        }
                    }
                }
            }
        }

        return result;
    }
};

fn jsonStr(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try w.print("\\u{x:0>4}", .{c});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
    try w.writeByte('"');
}
