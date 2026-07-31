// ESC watcher — cbreak stdin watch, port of taus StdinEscWatcher.
//
// Start a watcher coroutine on the Io runtime while the agent runs. It puts
// the terminal in cbreak mode (ICANON off, ECHO kept on) and reads stdin
// bytes directly. A bare ESC (not followed by '[' within ~150ms) sets the
// shared `fired` flag; arrow/function escape sequences are ignored.
// The agent loop checks `watcher.fired()` at loop detection points.
//
// On Windows, start()/stop() are no-ops.
const std = @import("std");
const Io = std.Io;

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

pub const Watcher = struct {
    io: Io,
    _fired: bool = false,
    _stop: bool = false,
    active: bool = false,
    _old: ?std.posix.termios = null,

    pub fn init(io: Io) Watcher {
        return .{ .io = io };
    }

    pub fn fired(self: *Watcher) bool {
        return @atomicLoad(bool, &self._fired, .acquire);
    }

    pub fn reset(self: *Watcher) void {
        @atomicStore(bool, &self._fired, false, .release);
    }

    /// Fire manually (e.g. from a Ctrl+C signal handler).
    pub fn fire(self: *Watcher) void {
        @atomicStore(bool, &self._fired, true, .release);
    }

    /// Start watching stdin for ESC. No-op on Windows or if already active.
    pub fn start(self: *Watcher, group: *Io.Group) void {
        if (self.active) return;
        if (!is_posix) return;
        self.active = true;
        @atomicStore(bool, &self._stop, false, .release);
        group.async(self.io, watchRun, .{self});
    }

    /// Stop watching and restore the terminal.
    pub fn stop(self: *Watcher) void {
        if (!self.active) return;
        @atomicStore(bool, &self._stop, true, .release);
        // Wait for the watch loop to notice and restore the terminal.
        var i: usize = 0;
        while (self.active and i < 50) : (i += 1) {
            Io.sleep(self.io, .fromMilliseconds(10), .awake) catch break;
        }
        restore(self);
    }
};

fn watchRun(w: *Watcher) void {
    defer w.active = false;
    if (!is_posix) return;

    const fd = std.posix.STDIN_FILENO;
    const old = std.posix.tcgetattr(fd) catch return;
    w._old = old;

    // cbreak: canonical off, VMIN=0 VTIME=1 (100ms read timeout), ECHO kept.
    var raw = old;
    raw.lflag.ICANON = false;
    raw.cc[CC_VMIN] = 0;
    raw.cc[CC_VTIME] = 1;
    std.posix.tcsetattr(fd, .NOW, raw) catch return;
    defer restore(w);

    var buf: [32]u8 = undefined;
    while (!@atomicLoad(bool, &w._stop, .acquire)) {
        const n = std.posix.read(fd, &buf) catch continue;
        if (n == 0) continue; // VTIME timeout — poll stop flag
        const data = buf[0..n];
        var i: usize = 0;
        while (i < data.len) : (i += 1) {
            if (data[i] != 0x1b) continue;
            // Distinguish bare ESC from escape sequences (arrows, F-keys):
            // a sequence is followed by '[' (CSI) or 'O' (SS3).
            if (i + 1 < data.len) {
                const next = data[i + 1];
                if (next == '[' or next == 'O') break; // sequence; drop the batch
            }
            w.fire();
        }
    }
}

fn restore(w: *Watcher) void {
    if (!is_posix) return;
    if (w._old) |old| {
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .DRAIN, old) catch {};
        w._old = null;
    }
}
