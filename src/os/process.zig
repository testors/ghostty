//! Information about other processes on this machine.
const std = @import("std");
const builtin = @import("builtin");
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
