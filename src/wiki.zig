// Wiki Manager — the agent's knowledge system.
// Progressive disclosure: index + aboutme in system prompt (L0),
// full articles loaded on demand via read tool (L1).
const std = @import("std");
const Io = std.Io;

pub const Wiki = struct {
    dir: []const u8, // absolute path to wiki dir (arena-owned)
    io: Io,

    pub fn exists(self: *const Wiki) bool {
        var d = Io.Dir.openDirAbsolute(self.io, self.dir, .{}) catch return false;
        defer d.close(self.io);
        d.access(self.io, "index.md", .{}) catch {
            d.access(self.io, "AGENT.md", .{}) catch return false;
            return true;
        };
        return true;
    }

    /// Initialize wiki with template files for REPL agent style.
    pub fn initRepl(self: *const Wiki, allocator: std.mem.Allocator, session_root: []const u8, username: []const u8) !void {
        try Io.Dir.createDirPath(.cwd(), self.io, self.dir);
        try Io.Dir.createDirPath(.cwd(), self.io, try join(allocator, &.{ self.dir, "capabilities" }));
        try Io.Dir.createDirPath(.cwd(), self.io, try join(allocator, &.{ self.dir, "memory" }));

        try writeFile(self.io, self.dir, "AGENT.md",
            \\# REPL Agent
            \\
            \\## 工具
            \\- read, write, edit, bash
            \\- create_agent, inject_skill, list_skills
            \\
            \\## 风格
            \\简洁高效，中文交流。
            \\先 read 再操作。
            \\
        );

        try writeFile(self.io, self.dir, "index.md",
            \\# Wiki Index
            \\
            \\## Identity
            \\- [About Me](aboutme.md) — Agent 身份、目的、风格
            \\
            \\## Environment
            \\- [Quick Memory](memory/quick.md) — 环境与安全规则
            \\- [Users](memory/users.md) — 用户信息
            \\
        );

        try writeFile(self.io, self.dir, "aboutme.md",
            \\# About Me
            \\
            \\## Identity
            \\- **Name**: repl
            \\
            \\## Style
            \\
            \\## Capabilities
            \\
            \\## Limitations
            \\
            \\
        );

        const quick = try std.fmt.allocPrint(allocator,
            \\# Quick Memory
            \\
            \\> 唯一每次启动载入的上下文。保持极简。
            \\
            \\## 环境
            \\- **系统**: macOS
            \\- **工作根目录**: {s}
            \\- **默认路径风格**: 绝对路径优先
            \\
            \\## 安全规则
            \\- 不执行破坏性命令未经确认
            \\- 不修改系统关键文件未经确认
            \\- 文件操作前先 read 确认内容
            \\
            \\## 用户
            \\- 用户名: {s}
            \\- 偏好: 中文交流，追求简洁高效
            \\
        , .{ session_root, username });
        try writeFile(self.io, self.dir, "memory/quick.md", quick);

        const users = try std.fmt.allocPrint(allocator,
            \\# User Information
            \\
            \\## Primary User
            \\- **Name**: {s}
            \\- **系统**: macOS
            \\- **工作目录**: {s}
            \\- **语言偏好**: 中文
            \\- **沟通风格**: 直接、简洁、务实
            \\
        , .{ username, session_root });
        try writeFile(self.io, self.dir, "memory/users.md", users);
    }

    /// Build the wiki section for system prompt injection. Allocated with gpa.
    pub fn systemPromptSection(self: *const Wiki, allocator: std.mem.Allocator) ![]u8 {
        if (!self.exists()) {
            return allocator.dupe(u8, "(No wiki configured — ask user to set one up)");
        }

        var buf: std.Io.Writer.Allocating = .init(allocator);
        const w = &buf.writer;

        try w.print("## Your Wiki\n\nYour wiki root is `{s}/`. ", .{self.dir});
        try w.writeAll("All article paths in this index are relative to this root. ");
        try w.print("Use absolute paths (e.g. `{s}/memory/quick.md`) when calling `read`, `write`, or `edit`.\n\n", .{self.dir});

        // Inject index.md content if present
        const index = Io.Dir.readFileAlloc(.cwd(), self.io, try join(allocator, &.{ self.dir, "index.md" }), allocator, .limited(64 * 1024)) catch null;
        if (index) |idx| {
            try w.writeAll(idx);
            try w.writeAll("\n");
        }

        var list = buf.toArrayList();
        return list.toOwnedSlice(allocator);
    }
};

pub fn join(allocator: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    return std.fs.path.join(allocator, parts);
}

fn writeFile(io: Io, dir: []const u8, sub_path: []const u8, data: []const u8) !void {
    const full = try std.fs.path.join(std.heap.page_allocator, &.{ dir, sub_path });
    defer std.heap.page_allocator.free(full);
    try Io.Dir.writeFile(.cwd(), io, .{ .sub_path = full, .data = data });
}
