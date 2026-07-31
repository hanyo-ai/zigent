// Tool registry and core tool implementations: read, write, edit, bash.
const std = @import("std");
const Io = std.Io;

pub const ToolSchema = struct {
    name: []const u8,
    description: []const u8,
    input_schema: []const u8, // raw JSON
};

pub const ToolHandler = *const fn (ctx: *ToolContext, input: std.json.Value) anyerror![]u8;

pub const ToolDef = struct {
    schema: ToolSchema,
    handler: ToolHandler,
};

/// Shared context passed to tool handlers (I/O + allocator).
pub const ToolContext = struct {
    allocator: std.mem.Allocator,
    io: Io,
};

pub const ToolRegistry = struct {
    tools: std.StringArrayHashMapUnmanaged(ToolDef) = .empty,

    pub fn register(self: *ToolRegistry, allocator: std.mem.Allocator, schema: ToolSchema, handler: ToolHandler) !void {
        try self.tools.put(allocator, schema.name, .{ .schema = schema, .handler = handler });
    }

    /// JSON array of tool schemas for the API request.
    pub fn schemasJson(self: *const ToolRegistry, allocator: std.mem.Allocator) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        const w = &aw.writer;
        try w.writeByte('[');
        for (self.tools.values(), 0..) |t, i| {
            if (i > 0) try w.writeByte(',');
            try w.writeAll("{\"name\":");
            try jsonStr(w, t.schema.name);
            try w.writeAll(",\"description\":");
            try jsonStr(w, t.schema.description);
            try w.writeAll(",\"input_schema\":");
            try w.writeAll(t.schema.input_schema);
            try w.writeByte('}');
        }
        try w.writeByte(']');
        var _list = aw.toArrayList();
        return _list.toOwnedSlice(allocator);
    }

    pub fn dispatch(self: *const ToolRegistry, tctx: *ToolContext, name: []const u8, input: std.json.Value) ![]u8 {
        const tool = self.tools.get(name) orelse {
            return std.fmt.allocPrint(tctx.allocator, "ERROR: unknown tool '{s}'. Available: {s}", .{ name, try self.namesString(tctx.allocator) });
        };
        return tool.handler(tctx, input) catch |err| {
            return std.fmt.allocPrint(tctx.allocator, "Error: {s}", .{@errorName(err)});
        };
    }

    fn namesString(self: *const ToolRegistry, allocator: std.mem.Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        for (self.tools.keys(), 0..) |k, i| {
            if (i > 0) try buf.append(allocator, ',');
            try buf.appendSlice(allocator, k);
        }
        return buf.toOwnedSlice(allocator);
    }
};

pub const TOOL_LABELS = [_]struct { name: []const u8, label: []const u8 }{
    .{ .name = "read", .label = "Read file contents (load wiki articles on demand)" },
    .{ .name = "write", .label = "Create or overwrite files" },
    .{ .name = "edit", .label = "Precisely edit files" },
    .{ .name = "bash", .label = "Execute shell commands" },
};

pub fn getToolLabel(name: []const u8) []const u8 {
    for (TOOL_LABELS) |tl| {
        if (std.mem.eql(u8, tl.name, name)) return tl.label;
    }
    return "(no description)";
}

// ── Schemas ──────────────────────────────────────────────────

const READ_SCHEMA =
    \\{"type":"object","properties":{
    \\  "path":{"type":"string","description":"Absolute or relative path to the file."},
    \\  "offset":{"type":"integer","description":"1-based line number to start reading from (default: 1)."},
    \\  "limit":{"type":"integer","description":"Maximum number of lines to return (default: 2000)."}
    \\},"required":["path"]}
;

const WRITE_SCHEMA =
    \\{"type":"object","properties":{
    \\  "path":{"type":"string","description":"Path of the file to create or overwrite."},
    \\  "content":{"type":"string","description":"Full file content to write."}
    \\},"required":["path","content"]}
;

const EDIT_SCHEMA =
    \\{"type":"object","properties":{
    \\  "path":{"type":"string","description":"Path to the file to edit."},
    \\  "edits":{"type":"array","description":"List of text replacements to apply.","items":{
    \\    "type":"object","properties":{
    \\      "oldText":{"type":"string","description":"Exact text to replace (unique in file)."},
    \\      "newText":{"type":"string","description":"Replacement text."}
    \\    },"required":["oldText","newText"]}
    \\  }
    \\},"required":["path","edits"]}
;

const BASH_SCHEMA =
    \\{"type":"object","properties":{
    \\  "command":{"type":"string","description":"Shell command to execute."},
    \\  "timeout":{"type":"integer","description":"Seconds before the command is killed (default 30, max 600)."}
    \\},"required":["command"]}
;

// ── Handlers ─────────────────────────────────────────────────

fn readHandler(ctx: *ToolContext, input: std.json.Value) ![]u8 {
    const allocator = ctx.allocator;
    const path_str = getString(input, "path") orelse return error.MissingPath;
    const offset: usize = getInt(input, "offset") orelse 1;
    const limit: usize = getInt(input, "limit") orelse 2000;

    // Stat to detect directory
    const stat = Io.Dir.statFile(.cwd(), ctx.io, path_str, .{}) catch {
        return std.fmt.allocPrint(allocator, "Error: File not found: {s}", .{path_str});
    };

    if (stat.kind == .directory) {
        var d = try Io.Dir.openDirAbsolute(ctx.io, path_str, .{ .iterate = true });
        defer d.close(ctx.io);

        const Entry = struct { name: []const u8, is_dir: bool };
        var names: std.ArrayList(Entry) = .empty;
        var it = d.iterate();
        while (try it.next(ctx.io)) |entry| {
            try names.append(allocator, .{
                .name = try allocator.dupe(u8, entry.name),
                .is_dir = entry.kind == .directory,
            });
        }

        std.mem.sort(Entry, names.items, {}, struct {
            fn less(_: void, a: Entry, b: Entry) bool {
                if (a.is_dir != b.is_dir) return a.is_dir;
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.less);

        var buf: std.Io.Writer.Allocating = .init(allocator);
        const w = &buf.writer;
        if (names.items.len == 0) {
            try w.writeAll("(empty directory)");
        } else {
            for (names.items) |e| {
                try w.print("{s}{s}\n", .{ e.name, if (e.is_dir) "/" else "" });
            }
        }
        var _list = buf.toArrayList();
        return _list.toOwnedSlice(allocator);
    }

    // Images: return path for markdown embedding
    const ext = std.fs.path.extension(path_str);
    const image_exts = [_][]const u8{ ".jpg", ".jpeg", ".png", ".gif", ".webp" };
    for (image_exts) |img| {
        if (std.ascii.eqlIgnoreCase(ext, img)) {
            const abs = try absPath(allocator, ctx.io, path_str);
            return std.fmt.allocPrint(allocator,
                "[Image] {s}\n\nTo display this image, use markdown:\n![description](http://127.0.0.1:8000/api/files?path={s})",
                .{ abs, abs },
            );
        }
    }

    // Read text file
    const text = Io.Dir.readFileAlloc(.cwd(), ctx.io, path_str, allocator, .limited(10 * 1024 * 1024)) catch |err| {
        return std.fmt.allocPrint(allocator, "Error: Cannot read {s} ({s})", .{ path_str, @errorName(err) });
    };

    const total = std.mem.count(u8, text, "\n") + 1;
    if (offset > total) {
        return std.fmt.allocPrint(allocator, "Error: offset {d} exceeds total lines {d}", .{ offset, total });
    }

    var buf: std.Io.Writer.Allocating = .init(allocator);
    const w = &buf.writer;

    var line_num: usize = 1;
    var consumed: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line_num >= offset) {
            if (consumed >= limit) break;
            try w.print("{d}\t{s}\n", .{ line_num, line });
            consumed += 1;
        }
        line_num += 1;
    }

    const processed = offset - 1 + consumed;
    if (processed < total) {
        try w.print("\n[Truncated: {d} more lines. Use offset={d} to continue.]", .{ total - processed, processed + 1 });
    }

    var _list = buf.toArrayList();
        return _list.toOwnedSlice(allocator);
}

fn writeHandler(ctx: *ToolContext, input: std.json.Value) ![]u8 {
    const allocator = ctx.allocator;
    const path_str = getString(input, "path") orelse return error.MissingPath;
    const content = getString(input, "content") orelse return error.MissingContent;

    // Create parent dirs
    if (std.fs.path.dirname(path_str)) |parent| {
        Io.Dir.createDirPath(.cwd(), ctx.io, parent) catch {};
    }

    try Io.Dir.writeFile(.cwd(), ctx.io, .{ .sub_path = path_str, .data = content });

    return std.fmt.allocPrint(allocator, "Wrote {d} bytes to {s}", .{ content.len, path_str });
}

fn editHandler(ctx: *ToolContext, input: std.json.Value) ![]u8 {
    const allocator = ctx.allocator;
    const path_str = getString(input, "path") orelse return error.MissingPath;
    const edits = input.object.get("edits") orelse return error.MissingEdits;
    if (edits != .array) return error.InvalidEdits;

    const original = Io.Dir.readFileAlloc(.cwd(), ctx.io, path_str, allocator, .limited(10 * 1024 * 1024)) catch {
        return std.fmt.allocPrint(allocator, "Error: File not found: {s}", .{path_str});
    };

    var text: []u8 = @constCast(original);
    var applied: usize = 0;

    for (edits.array.items) |edit_obj| {
        if (edit_obj != .object) return error.InvalidEdit;
        const old_text = getString(edit_obj, "oldText") orelse return error.MissingOldText;
        const new_text = getString(edit_obj, "newText") orelse return error.MissingNewText;

        // Exact match first
        if (std.mem.indexOf(u8, text, old_text)) |pos| {
            text = try std.mem.concat(allocator, u8, &.{ text[0..pos], new_text, text[pos + old_text.len ..] });
            applied += 1;
            continue;
        }

        // Fuzzy match: tolerate whitespace differences
        if (fuzzyFind(text, old_text)) |m| {
            text = try std.mem.concat(allocator, u8, &.{ text[0..m.start], new_text, text[m.end..] });
            applied += 1;
            continue;
        }

        return std.fmt.allocPrint(allocator, "Error: Could not find oldText in {s}: '{s}...'", .{
            path_str, old_text[0..@min(80, old_text.len)],
        });
    }

    try Io.Dir.writeFile(.cwd(), ctx.io, .{ .sub_path = path_str, .data = text });

    return std.fmt.allocPrint(allocator, "Applied {d} edit(s) to {s}", .{ edits.array.items.len, path_str });
}

const FuzzyMatch = struct { start: usize, end: usize };

/// Whitespace-tolerant search: each whitespace run in `pattern` matches any
/// whitespace run in `text`. Non-whitespace chars must match exactly.
fn fuzzyFind(text: []const u8, pattern: []const u8) ?FuzzyMatch {
    const trimmed = std.mem.trim(u8, pattern, " \t\r\n");
    if (trimmed.len == 0) return null;

    // Split pattern into whitespace-separated tokens
    var tokens: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, trimmed, " \t\r\n");
    while (it.next()) |tok| tokens.append(std.heap.page_allocator, tok) catch return null;
    if (tokens.items.len == 0) return null;

    // Scan text for start of first token
    var i: usize = 0;
    outer: while (i < text.len) : (i += 1) {
        var pos = i;
        for (tokens.items, 0..) |tok, ti| {
            if (ti > 0) {
                // Require at least one whitespace char between tokens
                if (pos >= text.len or !isWs(text[pos])) continue :outer;
                while (pos < text.len and isWs(text[pos])) pos += 1;
            }
            if (pos + tok.len > text.len) continue :outer;
            if (!std.mem.eql(u8, text[pos .. pos + tok.len], tok)) continue :outer;
            pos += tok.len;
        }
        return FuzzyMatch{ .start = i, .end = pos };
    }
    return null;
}

fn isWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn bashHandler(ctx: *ToolContext, input: std.json.Value) ![]u8 {
    const allocator = ctx.allocator;
    const command = getString(input, "command") orelse return error.MissingCommand;
    const timeout: i64 = @intCast(getInt(input, "timeout") orelse 30);
    const clamped_timeout: i64 = @min(@max(timeout, 1), 600);

    const result = std.process.run(allocator, ctx.io, .{
        .argv = &.{ "/bin/bash", "-c", command },
        .timeout = .{ .duration = .{ .raw = .fromSeconds(clamped_timeout), .clock = .awake } },
    }) catch |err| {
        return std.fmt.allocPrint(allocator, "Error: command failed ({s})", .{@errorName(err)});
    };

    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(allocator, result.stdout);
    try buf.appendSlice(allocator, result.stderr);

    const output = buf.items;

    // Truncate at 2000 lines
    const total_lines = std.mem.count(u8, output, "\n") + 1;
    if (total_lines > 2000) {
        var truncated: std.Io.Writer.Allocating = .init(allocator);
        const w = &truncated.writer;
        var line_it = std.mem.splitScalar(u8, output, '\n');
        var count: usize = 0;
        while (line_it.next()) |line| : (count += 1) {
            if (count >= 2000) break;
            try w.print("{s}\n", .{line});
        }
        try w.print("\n[Output truncated: {d} more lines.]", .{total_lines - 2000});
        var _list = truncated.toArrayList();
        return _list.toOwnedSlice(allocator);
    }

    if (output.len == 0) return allocator.dupe(u8, "(no output)");
    return buf.toOwnedSlice(allocator);
}

// ── Helpers ──────────────────────────────────────────────────

fn getString(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const item = v.object.get(key) orelse return null;
    if (item != .string) return null;
    return item.string;
}

fn getInt(v: std.json.Value, key: []const u8) ?usize {
    if (v != .object) return null;
    const item = v.object.get(key) orelse return null;
    if (item != .integer) return null;
    if (item.integer < 0) return null;
    return @intCast(item.integer);
}

fn absPath(allocator: std.mem.Allocator, io: Io, path_str: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path_str)) return allocator.dupe(u8, path_str);
    var buf: [4096]u8 = undefined;
    const n = try Io.Dir.realPathFile(.cwd(), io, path_str, &buf);
    return allocator.dupe(u8, buf[0..n]);
}

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

// ── Build core registry ──────────────────────────────────────

pub fn buildCoreRegistry(allocator: std.mem.Allocator) !ToolRegistry {
    var reg = ToolRegistry{};

    try reg.register(allocator, .{
        .name = "read",
        .description = "Read the contents of a file at a given path. For text files, returns lines with 1-based line numbers. Supports pagination via offset/limit to read large files in chunks — use offset=N to continue reading after a truncation hint. For images (jpg, jpeg, png, gif, webp) returns the image as a base64-encoded attachment. Output is capped at 2000 lines / 50 KB; a continuation hint is appended when truncation occurs.",
        .input_schema = READ_SCHEMA,
    }, readHandler);

    try reg.register(allocator, .{
        .name = "write",
        .description = "Create a new file or completely overwrite an existing file with the given content. Parent directories are created automatically. Use write only for new files or full rewrites — for targeted changes to existing files, use the edit tool instead. New files default to the ./temp/ directory.",
        .input_schema = WRITE_SCHEMA,
    }, writeHandler);

    try reg.register(allocator, .{
        .name = "edit",
        .description = "Make precise edits to an existing file by replacing exact text snippets. Each entry in edits[] specifies oldText (the text to find) and newText (its replacement). oldText is matched using fuzzy matching that tolerates minor whitespace/indentation differences, but must be unique within the file. All edits are applied against the ORIGINAL file content in parallel — earlier edits do NOT shift the offsets of later edits, so you can safely include multiple non-overlapping edits in a single call. Use one edit call with multiple edits[] entries rather than multiple sequential calls when editing several locations in the same file. Keep oldText as small as possible while still being unique.",
        .input_schema = EDIT_SCHEMA,
    }, editHandler);

    try reg.register(allocator, .{
        .name = "bash",
        .description = "Execute a shell command in bash and return the combined stdout/stderr output. Use for file operations (ls, grep, find, rg), running scripts, installing packages, and any other shell tasks. Output is capped at 2000 lines / 50 KB; when truncated the full output is written to a temp file whose path is included. The timeout parameter (default 30s) kills the entire process tree on expiry.",
        .input_schema = BASH_SCHEMA,
    }, bashHandler);

    return reg;
}
