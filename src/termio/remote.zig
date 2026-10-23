//! Detects when a terminal is connected to another machine, so apprts can
//! show that input goes to a remote host.
//!
//! The terminal is remote while a remote client (ssh, mosh, ...) is in the
//! foreground process group of its pty. This is all a terminal can know
//! for certain: which host is receiving input can't be known reliably
//! (the client may have connected onwards to other hosts), so it isn't
//! reported.
const std = @import("std");
const builtin = @import("builtin");
const internal_os = @import("../os/main.zig");

/// A program that connects the terminal to another machine.
pub const Program = enum {
    ssh,
    mosh,
    et,
    telnet,

    /// The name shown to users.
    pub fn name(self: Program) [:0]const u8 {
        return @tagName(self);
    }
};

/// The remote client a process name belongs to, or null if it isn't one.
pub fn classify(process_name: []const u8) ?Program {
    var n = std.fs.path.basename(process_name);
    // Login shells are started as "-zsh".
    if (n.len > 1 and n[0] == '-') n = n[1..];

    const programs = std.StaticStringMap(Program).initComptime(.{
        .{ "ssh", .ssh },
        .{ "slogin", .ssh },
        .{ "autossh", .ssh },
        .{ "mosh", .mosh },
        .{ "mosh-client", .mosh },
        .{ "et", .et },
        .{ "telnet", .telnet },
    });
    return programs.get(n);
}

/// The remote client in the foreground process group `pgid` of a pty, or
/// null if there is none.
pub fn foreground(pgid: ?u64) ?Program {
    const group = pgid orelse return null;

    // Any member of the group may be the client: the group leader isn't
    // always it (see groupMembers).
    var pids: [16]u64 = undefined;
    var name_buf: [256]u8 = undefined;
    for (internal_os.process.groupMembers(&pids, group)) |pid| {
        const name = internal_os.process.name(&name_buf, pid) orelse continue;
        if (classify(name)) |program| return program;
    }

    return null;
}

test "classify" {
    const testing = std.testing;
    try testing.expectEqual(Program.ssh, classify("ssh").?);
    try testing.expectEqual(Program.ssh, classify("/usr/bin/ssh").?);
    try testing.expectEqual(Program.ssh, classify("autossh").?);
    try testing.expectEqual(Program.mosh, classify("mosh-client").?);
    try testing.expectEqual(Program.et, classify("et").?);
    try testing.expectEqual(Program.telnet, classify("telnet").?);
    try testing.expect(classify("-zsh") == null);
    try testing.expect(classify("sshd") == null);
    try testing.expect(classify("vim") == null);
    try testing.expect(classify("") == null);
}

test "foreground" {
    const testing = std.testing;
    try testing.expect(foreground(null) == null);
    if (comptime builtin.target.os.tag == .windows) return;

    // The test runner isn't a remote client.
    const getpgrp = struct {
        extern "c" fn getpgrp() c_int;
    }.getpgrp;
    try testing.expect(foreground(@intCast(getpgrp())) == null);
}
