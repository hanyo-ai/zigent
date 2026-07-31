// Message context — stores conversation history in Anthropic format.
const std = @import("std");

pub const Role = enum { user, assistant };

pub const BlockType = enum { text, tool_use, tool_result };

pub const Block = struct {
    block_type: BlockType,
    text: []const u8 = "", // text content or tool_result content
    id: []const u8 = "", // tool_use id / tool_result tool_use_id
    name: []const u8 = "", // tool_use name
    input_json: []const u8 = "", // tool_use input as raw JSON
    is_error: bool = false,
};

pub const Message = struct {
    role: Role,
    /// For simple user text messages.
    text: []const u8 = "",
    /// For assistant messages (text+tool_use blocks) and user tool_result messages.
    blocks: std.ArrayList(Block) = .empty,
};

pub const Context = struct {
    messages: std.ArrayList(Message) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Context {
        return .{ .allocator = allocator };
    }

    pub fn addUser(self: *Context, text: []const u8) !void {
        try self.messages.append(self.allocator, .{
            .role = .user,
            .text = try self.allocator.dupe(u8, text),
        });
    }

    /// Takes ownership of blocks slice contents (already allocator-owned).
    pub fn addAssistant(self: *Context, blocks: std.ArrayList(Block)) !void {
        try self.messages.append(self.allocator, .{
            .role = .assistant,
            .blocks = blocks,
        });
    }

    pub fn addToolResults(self: *Context, results: []const Block) !void {
        var blocks: std.ArrayList(Block) = .empty;
        for (results) |r| {
            try blocks.append(self.allocator, .{
                .block_type = .tool_result,
                .text = try self.allocator.dupe(u8, r.text),
                .id = try self.allocator.dupe(u8, r.id),
                .is_error = r.is_error,
            });
        }
        try self.messages.append(self.allocator, .{
            .role = .user,
            .blocks = blocks,
        });
    }

    /// Serialize to the Anthropic messages JSON array. Caller owns memory.
    pub fn toJson(self: *const Context) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        const w = &aw.writer;

        try w.writeByte('[');
        for (self.messages.items, 0..) |msg, i| {
            if (i > 0) try w.writeByte(',');
            try w.print("{{\"role\":\"{s}\",\"content\":", .{@tagName(msg.role)});

            if (msg.blocks.items.len == 0) {
                try writeJsonString(w, msg.text);
            } else {
                try w.writeByte('[');
                for (msg.blocks.items, 0..) |block, j| {
                    if (j > 0) try w.writeByte(',');
                    switch (block.block_type) {
                        .text => {
                            try w.writeAll("{\"type\":\"text\",\"text\":");
                            try writeJsonString(w, block.text);
                            try w.writeByte('}');
                        },
                        .tool_use => {
                            try w.writeAll("{\"type\":\"tool_use\",\"id\":");
                            try writeJsonString(w, block.id);
                            try w.writeAll(",\"name\":");
                            try writeJsonString(w, block.name);
                            try w.writeAll(",\"input\":");
                            try w.writeAll(if (block.input_json.len > 0) block.input_json else "{}");
                            try w.writeByte('}');
                        },
                        .tool_result => {
                            try w.writeAll("{\"type\":\"tool_result\",\"tool_use_id\":");
                            try writeJsonString(w, block.id);
                            if (block.is_error) {
                                try w.writeAll(",\"is_error\":true");
                            }
                            try w.writeAll(",\"content\":");
                            try writeJsonString(w, block.text);
                            try w.writeByte('}');
                        },
                    }
                }
                try w.writeByte(']');
            }
            try w.writeByte('}');
        }
        try w.writeByte(']');
        var _list = aw.toArrayList();
        return _list.toOwnedSlice(self.allocator);
    }

    /// If last message is assistant with tool_use blocks lacking results, pop it.
    pub fn rollbackOrphanedToolUse(self: *Context) void {
        if (self.messages.items.len == 0) return;
        const last = &self.messages.items[self.messages.items.len - 1];
        if (last.role != .assistant) return;
        for (last.blocks.items) |b| {
            if (b.block_type == .tool_use) {
                _ = self.messages.pop();
                return;
            }
        }
    }
};

pub fn writeJsonString(w: anytype, s: []const u8) !void {
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
