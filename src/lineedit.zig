// lineedit.zig — raw-mode line editor with slash-command completion + history.
//
// Replaces canonical-mode line reading so that typing "/" shows matching
// commands below the input line (like taus' prompt_toolkit SlashCompleter):
//   - matches update on every keystroke
//   - Tab completes to the common prefix (full command + space if unique)
//   - ↑/↓ browse history, ←/→ move the cursor (UTF-8 aware)
//   - Ctrl+C cancels the line (returns ""), Ctrl+D on empty line = EOF (null)
const std = @import("std");

const is_posix = switch (@import("builtin").os.tag) {
    .windows, .wasi => false,
    else => true,
};

// Control-character indices into termios.cc (not exported by std).
const CC_VMIN: usize = switch (@import("builtin").os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos, .driverkit => 16,
    .freebsd, .netbsd, .dragonfly, .openbsd => 16,
    else => 6, // linux
};
const CC_VTIME: usize = switch (@import("builtin").os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos, .driverkit => 17,
    .freebsd, .netbsd, .dragonfly, .openbsd => 17,
    else => 5, // linux
};

pub const Command = struct { name: []const u8, desc: []const u8 };

/// Slash commands offered by the completer (primary aliases only).
pub const COMMANDS = [_]Command{
    .{ .name = "/help", .desc = "显示帮助" },
    .{ .name = "/exit", .desc = "退出" },
    .{ .name = "/clear", .desc = "清屏" },
    .{ .name = "/model", .desc = "显示当前模型配置" },
    .{ .name = "/usage", .desc = "上下文窗口用量明细" },
    .{ .name = "/go", .desc = "继续（暂停后）" },
    .{ .name = "/abort", .desc = "中止（暂停后）" },
};

const MAX_MATCHES = 8;
const NAME_PAD = 10;

const MatchList = struct {
    items: [MAX_MATCHES]*const Command = undefined,
    len: usize = 0,
};

pub const Editor = struct {
    allocator: std.mem.Allocator,
    history: std.ArrayList([]const u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) Editor {
        return .{ .allocator = allocator };
    }

    /// Read one line at `prompt` (display width `prompt_width`, ANSI codes
    /// excluded). Returns the line (caller-owned), "" for Ctrl+C-cancelled
    /// input, or null for Ctrl+D on an empty line.
    pub fn readLine(self: *Editor, prompt: []const u8, prompt_width: usize) !?[]u8 {
        if (!is_posix) return error.Unsupported;
        const fd_in = std.posix.STDIN_FILENO;

        const old = std.posix.tcgetattr(fd_in) catch return error.NoTty;
        var raw = old;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ISIG = false;
        raw.cc[CC_VMIN] = 1;
        raw.cc[CC_VTIME] = 0;
        try std.posix.tcsetattr(fd_in, .NOW, raw);
        defer std.posix.tcsetattr(fd_in, .NOW, old) catch {};

        var buf: std.ArrayList(u8) = .empty;
        var cursor: usize = 0;
        var hist_idx: ?usize = null;
        var saved: std.ArrayList(u8) = .empty; // stashed line while browsing history

        try render(prompt, prompt_width, buf.items, cursor);

        while (true) {
            const b = try readByte(fd_in);
            switch (b) {
                '\r', '\n' => {
                    try writeAll("\r\x1b[J");
                    try writeAll(prompt);
                    try writeAll(buf.items);
                    try writeAll("\n");
                    const line = try self.allocator.dupe(u8, buf.items);
                    if (line.len > 0) try self.history.append(self.allocator, line);
                    return line;
                },
                0x03 => { // Ctrl+C — cancel current input
                    try writeAll("\r\x1b[J");
                    try writeAll(prompt);
                    try writeAll(buf.items);
                    try writeAll("^C\n");
                    return try self.allocator.dupe(u8, "");
                },
                0x04 => { // Ctrl+D — EOF only on empty line
                    if (buf.items.len == 0) {
                        try writeAll("\r\x1b[J");
                        try writeAll(prompt);
                        return null;
                    }
                },
                0x7f, 0x08 => { // backspace (whole UTF-8 char)
                    if (cursor > 0) {
                        const start = prevCharBoundary(buf.items, cursor);
                        std.mem.copyForwards(u8, buf.items[start..], buf.items[cursor..]);
                        buf.items.len -= cursor - start;
                        cursor = start;
                    }
                    hist_idx = null;
                },
                0x09 => complete(&buf, &cursor, self.allocator), // Tab
                0x1b => { // escape sequence (arrows etc.)
                    var tail: [8]u8 = undefined;
                    const n = readEscTail(fd_in, &tail);
                    if (n >= 2 and tail[0] == '[') {
                        switch (tail[1]) {
                            'A' => { // up — older history
                                if (self.history.items.len > 0) {
                                    if (hist_idx) |hi| {
                                        if (hi > 0) hist_idx = hi - 1;
                                    } else {
                                        saved.clearRetainingCapacity();
                                        try saved.appendSlice(self.allocator, buf.items);
                                        hist_idx = self.history.items.len - 1;
                                    }
                                    buf.clearRetainingCapacity();
                                    try buf.appendSlice(self.allocator, self.history.items[hist_idx.?]);
                                    cursor = buf.items.len;
                                }
                            },
                            'B' => { // down — newer history / restore saved line
                                if (hist_idx) |hi| {
                                    buf.clearRetainingCapacity();
                                    if (hi + 1 < self.history.items.len) {
                                        hist_idx = hi + 1;
                                        try buf.appendSlice(self.allocator, self.history.items[hist_idx.?]);
                                    } else {
                                        hist_idx = null;
                                        try buf.appendSlice(self.allocator, saved.items);
                                    }
                                    cursor = buf.items.len;
                                }
                            },
                            'C' => { // right
                                if (cursor < buf.items.len) cursor += utf8Len(buf.items[cursor]);
                            },
                            'D' => { // left
                                if (cursor > 0) cursor = prevCharBoundary(buf.items, cursor);
                            },
                            else => {},
                        }
                    }
                },
                else => {
                    if (b >= 0x20) { // printable / UTF-8 byte
                        try buf.insert(self.allocator, cursor, b);
                        cursor += 1;
                        hist_idx = null;
                    }
                },
            }
            try render(prompt, prompt_width, buf.items, cursor);
        }
    }
};

// ── Completion ───────────────────────────────────────────────

fn matchCommands(buf: []const u8) MatchList {
    var out: MatchList = .{};
    if (buf.len == 0 or buf[0] != '/') return out;
    if (std.mem.indexOfScalar(u8, buf, ' ') != null) return out; // typing args
    for (&COMMANDS) |*cmd| {
        if (out.len >= MAX_MATCHES) break;
        if (std.mem.startsWith(u8, cmd.name, buf)) {
            out.items[out.len] = cmd;
            out.len += 1;
        }
    }
    return out;
}

fn complete(buf: *std.ArrayList(u8), cursor: *usize, allocator: std.mem.Allocator) void {
    const m = matchCommands(buf.items);
    if (m.len == 0) return;

    // Longest common prefix of all matches.
    var prefix: []const u8 = m.items[0].name;
    for (m.items[1..m.len]) |cmd| {
        var i: usize = 0;
        while (i < prefix.len and i < cmd.name.len and prefix[i] == cmd.name[i]) i += 1;
        prefix = prefix[0..i];
    }

    if (m.len == 1 and std.mem.eql(u8, buf.items, m.items[0].name)) {
        // Already fully typed: append a space.
        buf.append(allocator, ' ') catch return;
        cursor.* = buf.items.len;
        return;
    }
    if (prefix.len > buf.items.len) {
        buf.clearRetainingCapacity();
        buf.appendSlice(allocator, prefix) catch return;
        cursor.* = buf.items.len;
    }
}

// ── Rendering ────────────────────────────────────────────────

fn render(prompt: []const u8, prompt_width: usize, buf: []const u8, cursor: usize) !void {
    try writeAll("\r\x1b[J"); // line start + clear everything below
    try writeAll(prompt);
    try writeAll(buf);

    const m = matchCommands(buf);
    var shown: usize = 0;
    for (m.items[0..m.len]) |cmd| {
        shown += 1;
        var line_buf: [128]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "\n\x1b[90m{s}", .{cmd.name}) catch continue;
        try writeAll(line);
        var pad: usize = if (cmd.name.len < NAME_PAD) NAME_PAD - cmd.name.len else 1;
        while (pad > 0) : (pad -= 1) try writeAll(" ");
        try writeAll(cmd.desc);
        try writeAll("\x1b[0m");
    }

    if (shown > 0) {
        var up_buf: [16]u8 = undefined;
        const up = std.fmt.bufPrint(&up_buf, "\x1b[{d}A", .{shown}) catch "";
        try writeAll(up);
    }
    try writeAll("\r");
    const col = prompt_width + displayWidth(buf[0..cursor]);
    if (col > 0) {
        var c_buf: [16]u8 = undefined;
        const c = std.fmt.bufPrint(&c_buf, "\x1b[{d}C", .{col}) catch "";
        try writeAll(c);
    }
}

/// Rough terminal cell width: ASCII = 1, multibyte UTF-8 lead = 2 (CJK).
fn displayWidth(s: []const u8) usize {
    var w: usize = 0;
    for (s) |b| {
        if (b & 0xC0 == 0x80) continue; // continuation byte
        w += if (b >= 0x80) 2 else 1;
    }
    return w;
}

// ── Low-level I/O ────────────────────────────────────────────

fn readByte(fd: std.posix.fd_t) !u8 {
    var b: [1]u8 = undefined;
    while (true) {
        const n = try std.posix.read(fd, &b);
        if (n == 1) return b[0];
    }
}

/// After ESC, read the rest of an escape sequence (best effort, ~50ms).
fn readEscTail(fd: std.posix.fd_t, out: []u8) usize {
    var n: usize = 0;
    while (n < out.len) {
        var pfd = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = std.posix.poll(&pfd, 50) catch return n;
        if (ready == 0) return n;
        var b: [1]u8 = undefined;
        const r = std.posix.read(fd, &b) catch return n;
        if (r == 0) return n;
        out[n] = b[0];
        n += 1;
        // CSI sequences end with a final byte in @A–Z[a–z]~.
        if (n >= 2 and out[0] == '[' and b[0] >= 0x40) break;
    }
    return n;
}

fn writeAll(bytes: []const u8) !void {
    var rest = bytes;
    while (rest.len > 0) {
        const rc = std.posix.system.write(std.posix.STDOUT_FILENO, rest.ptr, rest.len);
        if (std.posix.errno(rc) != .SUCCESS) return error.WriteFailed;
        rest = rest[@intCast(rc)..];
    }
}

// ── UTF-8 helpers ────────────────────────────────────────────

fn utf8Len(b: u8) usize {
    if (b < 0x80) return 1;
    if (b >> 5 == 0b110) return 2;
    if (b >> 4 == 0b1110) return 3;
    return 4;
}

fn prevCharBoundary(s: []const u8, cursor: usize) usize {
    var i = cursor - 1;
    while (i > 0 and (s[i] & 0xC0) == 0x80) i -= 1;
    return i;
}

// ── Tests ────────────────────────────────────────────────────

test "matchCommands filters slash commands by prefix" {
    var m = matchCommands("/");
    try std.testing.expectEqual(@as(usize, 7), m.len);
    try std.testing.expectEqualStrings("/help", m.items[0].name);

    m = matchCommands("/us");
    try std.testing.expectEqual(@as(usize, 1), m.len);
    try std.testing.expectEqualStrings("/usage", m.items[0].name);

    m = matchCommands("/m");
    try std.testing.expectEqual(@as(usize, 1), m.len);
    try std.testing.expectEqualStrings("/model", m.items[0].name);

    // No matches / not a command / typing args
    try std.testing.expectEqual(@as(usize, 0), matchCommands("/xyz").len);
    try std.testing.expectEqual(@as(usize, 0), matchCommands("hello").len);
    try std.testing.expectEqual(@as(usize, 0), matchCommands("/model x").len);
}

test "complete extends to common prefix and full command" {
    const alloc = std.testing.allocator;

    // Unique match: "/us" + Tab → "/usage"
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var cursor: usize = 0;
    try buf.appendSlice(alloc, "/us");
    cursor = 3;
    complete(&buf, &cursor, alloc);
    try std.testing.expectEqualStrings("/usage", buf.items);

    // Already complete: appends a space
    complete(&buf, &cursor, alloc);
    try std.testing.expectEqualStrings("/usage ", buf.items);

    // Ambiguous "/e" (exit) unique here; "/a" → "/abort"
    buf.clearRetainingCapacity();
    try buf.appendSlice(alloc, "/a");
    cursor = 2;
    complete(&buf, &cursor, alloc);
    try std.testing.expectEqualStrings("/abort", buf.items);

    // No-op when not a command
    buf.clearRetainingCapacity();
    try buf.appendSlice(alloc, "hello");
    cursor = 5;
    complete(&buf, &cursor, alloc);
    try std.testing.expectEqualStrings("hello", buf.items);
}

test "displayWidth counts CJK as 2" {
    try std.testing.expectEqual(@as(usize, 2), displayWidth("> "));
    try std.testing.expectEqual(@as(usize, 6), displayWidth("> 中文"));
}

test "prevCharBoundary walks UTF-8 continuations" {
    const s = "/中文";
    try std.testing.expectEqual(@as(usize, 1), prevCharBoundary(s, 4));
    try std.testing.expectEqual(@as(usize, 1), prevCharBoundary(s, 3));
    try std.testing.expectEqual(@as(usize, 1), prevCharBoundary(s, 2));
    try std.testing.expectEqual(@as(usize, 0), prevCharBoundary(s, 1));
}
