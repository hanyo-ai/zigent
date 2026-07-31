// String buffer helper wrapping std.Io.Writer.Allocating.
const std = @import("std");
const Io = std.Io;

pub const StrBuf = struct {
    aw: Io.Writer.Allocating,

    pub fn init(allocator: std.mem.Allocator) StrBuf {
        return .{ .aw = .init(allocator) };
    }

    pub fn w(self: *StrBuf) *Io.Writer {
        return &self.aw.writer;
    }

    pub fn items(self: *const StrBuf) []const u8 {
        return self.aw.writer.buffered();
    }

    /// Caller owns the returned slice (allocated with the allocator passed to init).
    pub fn toOwned(self: *StrBuf, allocator: std.mem.Allocator) ![]u8 {
        return allocator.dupe(u8, self.items());
    }

    pub fn clear(self: *StrBuf) void {
        self.aw.clearRetainingCapacity();
    }
};
