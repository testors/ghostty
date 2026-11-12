//! Information about other processes on this machine.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const global = @import("../global.zig");

/// The name of the process with the given pid (e.g. "ssh"), written to
/// `buf`. Returns null if the information isn't available (the process
/// exited, we don't have permission, or the platform isn't supported).
pub fn name(buf: []u8, pid: u64) ?[]const u8 {
    return switch (builtin.target.os.tag) {
        .macos => nameDarwin(buf, pid),
        .linux => nameProc(buf, pid) catch null,
        else => null,
    };
}

fn nameDarwin(buf: []u8, pid: u64) ?[]const u8 {
    const len = proc_name(@intCast(pid), buf.ptr, @intCast(buf.len));
    if (len <= 0) return null;
    return buf[0..@intCast(len)];
}

extern "c" fn proc_name(pid: c_int, buffer: [*]u8, buffersize: u32) c_int;

/// Linux: /proc/<pid>/comm holds the name followed by a newline.
fn nameProc(buf: []u8, pid: u64) ![]const u8 {
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/proc/{d}/comm", .{pid});
    const data = try std.Io.Dir.cwd().readFile(global.io(), path, buf);
    return std.mem.trimEnd(u8, data, "\n");
}

/// The command line of the process with the given pid, starting with
/// argv[0]. Each argument is followed by a NUL byte. Returns null if the
/// information isn't available (the process exited, we don't have
/// permission, or the platform isn't supported). The caller owns the
/// returned memory. Use `argsIterator` to read it.
pub fn argsAlloc(alloc: Allocator, pid: u64) Allocator.Error!?[]u8 {
    return switch (builtin.target.os.tag) {
        .macos => argsDarwin(alloc, pid),
        .linux => argsProc(alloc, pid),
        else => null,
    };
}

/// Iterates over the arguments returned by `argsAlloc`.
pub fn argsIterator(args: []const u8) std.mem.SplitIterator(u8, .scalar) {
    return std.mem.splitScalar(u8, std.mem.trimEnd(u8, args, "\x00"), 0);
}

/// macOS: KERN_PROCARGS2 gives argc, the executable path, padding and
/// then the arguments, followed by the environment.
fn argsDarwin(alloc: Allocator, pid: u64) Allocator.Error!?[]u8 {
    const CTL_KERN = 1;
    const KERN_ARGMAX = 8;
    const KERN_PROCARGS2 = 49;

    var argmax: c_int = 0;
    var size: usize = @sizeOf(c_int);
    const argmax_mib = [_]c_int{ CTL_KERN, KERN_ARGMAX };
    if (std.c.sysctl(&argmax_mib, argmax_mib.len, &argmax, &size, null, 0) != 0) return null;
    if (argmax <= @sizeOf(c_int)) return null;

    const buf = try alloc.alloc(u8, @intCast(argmax));
    defer alloc.free(buf);
    size = buf.len;
    const mib = [_]c_int{ CTL_KERN, KERN_PROCARGS2, std.math.cast(c_int, pid) orelse return null };
    if (std.c.sysctl(&mib, mib.len, buf.ptr, &size, null, 0) != 0) return null;
    if (size < @sizeOf(c_int)) return null;

    const argc = std.mem.readInt(c_int, buf[0..@sizeOf(c_int)], builtin.cpu.arch.endian());
    if (argc <= 0) return null;

    // Skip the executable path and the NUL bytes padding it.
    const data = buf[@sizeOf(c_int)..size];
    var start = std.mem.indexOfScalar(u8, data, 0) orelse return null;
    while (start < data.len and data[start] == 0) start += 1;

    var end = start;
    for (0..@intCast(argc)) |_| {
        const nul = std.mem.indexOfScalarPos(u8, data, end, 0) orelse return null;
        end = nul + 1;
    }

    return try alloc.dupe(u8, data[start..end]);
}

/// Linux: /proc/<pid>/cmdline holds the arguments, each followed by NUL.
fn argsProc(alloc: Allocator, pid: u64) Allocator.Error!?[]u8 {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/cmdline", .{pid}) catch return null;
    var buf: [32 * 1024]u8 = undefined;
    const data = std.Io.Dir.cwd().readFile(global.io(), path, &buf) catch return null;
    if (data.len == 0) return null;
    return try alloc.dupe(u8, data);
}

/// The processes in the process group `pgid`, starting with the group
/// leader, written to `buf` (which must hold at least one pid). On macOS
/// the shells of terminals run under `login`, which is owned by root, so
/// the leader of a terminal's foreground group may be a process we can't
/// inspect while its other members are ours. Elsewhere only the leader is
/// returned.
pub fn groupMembers(buf: []u64, pgid: u64) []const u64 {
    buf[0] = pgid;
    var len: usize = 1;

    if (comptime builtin.target.os.tag == .macos) members: {
        const PROC_PGRP_ONLY = 2;
        var pids: [64]c_int = undefined;
        const bytes = proc_listpids(
            PROC_PGRP_ONLY,
            @intCast(pgid),
            &pids,
            @intCast(@sizeOf(@TypeOf(pids))),
        );
        if (bytes <= 0) break :members;
        const count: usize = @as(usize, @intCast(bytes)) / @sizeOf(c_int);
        for (pids[0..@min(count, pids.len)]) |pid| {
            if (pid <= 0 or pid == pgid) continue;
            if (len == buf.len) break;
            buf[len] = @intCast(pid);
            len += 1;
        }
    }

    return buf[0..len];
}

extern "c" fn proc_listpids(
    type: u32,
    typeinfo: u32,
    buffer: ?*anyopaque,
    buffersize: c_int,
) c_int;

test "name of this process" {
    if (comptime builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) {
        return error.SkipZigTest;
    }

    const testing = std.testing;
    var buf: [256]u8 = undefined;
    const pid: u64 = @intCast(std.c.getpid());
    const result = name(&buf, pid) orelse return error.TestUnexpectedNull;
    try testing.expect(result.len > 0);
    try testing.expect(std.mem.indexOfScalar(u8, result, '\n') == null);
}

test "args of this process" {
    if (comptime builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) {
        return error.SkipZigTest;
    }

    const testing = std.testing;
    const pid: u64 = @intCast(std.c.getpid());
    const args = try argsAlloc(testing.allocator, pid) orelse return error.TestUnexpectedNull;
    defer testing.allocator.free(args);

    // argv[0] names the test binary, the same one the name came from.
    var it = argsIterator(args);
    const argv0 = it.next() orelse return error.TestUnexpectedNull;
    var name_buf: [256]u8 = undefined;
    const process_name = name(&name_buf, pid) orelse return error.TestUnexpectedNull;
    try testing.expect(std.mem.startsWith(
        u8,
        std.fs.path.basename(argv0),
        process_name,
    ));
}

test "groupMembers includes the leader" {
    if (comptime builtin.target.os.tag == .windows) return error.SkipZigTest;

    const testing = std.testing;
    const getpgrp = struct {
        extern "c" fn getpgrp() c_int;
    }.getpgrp;
    const pgid: u64 = @intCast(getpgrp());
    var buf: [16]u64 = undefined;
    const members = groupMembers(&buf, pgid);
    try testing.expect(members.len >= 1);
    try testing.expectEqual(pgid, members[0]);
}
