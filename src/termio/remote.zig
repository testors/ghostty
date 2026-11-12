//! Detects when a terminal is connected to another machine, so apprts can
//! show that input goes to a remote host.
//!
//! The terminal is remote while a remote client (ssh, mosh, ...) is in the
//! foreground process group of its pty. This is all a terminal can know
//! for certain: which host is receiving input can't be known reliably
//! (the client may have connected onwards to other hosts), so it isn't
//! reported. The host the client connected to can be read from its
//! command line, though, to fetch files from it (see `sshArgs`).
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
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

/// The ssh(1) arguments that reach the host of the remote client in the
/// foreground process group `pgid` of a pty: see `sshArgs`. Null if there
/// is no remote client or its host can't be known. The result is
/// allocated with `alloc`, which should be an arena.
pub fn foregroundSshArgs(
    alloc: Allocator,
    pgid: ?u64,
) Allocator.Error!?[]const []const u8 {
    const group = pgid orelse return null;

    var pids: [16]u64 = undefined;
    var name_buf: [256]u8 = undefined;
    for (internal_os.process.groupMembers(&pids, group)) |pid| {
        const name = internal_os.process.name(&name_buf, pid) orelse continue;
        const program = classify(name) orelse continue;
        const args = try internal_os.process.argsAlloc(alloc, pid) orelse continue;

        var argv: std.ArrayList([]const u8) = .empty;
        var it = internal_os.process.argsIterator(args);
        while (it.next()) |arg| try argv.append(alloc, arg);
        return try sshArgs(alloc, program, argv.items);
    }

    return null;
}

/// The ssh(1) arguments that reach the host a remote client is connected
/// to, given the client's command line `argv` (starting with argv[0]):
/// the options that choose how to connect, then the destination. A
/// remote command can be added after them. Null if the host can't be
/// known from the command line.
///
/// For ssh, options that do more than connect, such as port forwarding
/// or a forced tty, are left out.
///
/// For mosh, the destination is read from the "-# <mosh arguments> |"
/// argument that mosh gives mosh-client. mosh joins its arguments with
/// spaces there, so options it gave ssh with --ssh are lost; a port or
/// user for the host has to come from ~/.ssh/config.
///
/// The result is allocated with `alloc`, which should be an arena, and
/// may point into `argv`.
pub fn sshArgs(
    alloc: Allocator,
    program: Program,
    argv: []const []const u8,
) Allocator.Error!?[]const []const u8 {
    if (argv.len == 0) return null;
    return switch (program) {
        .ssh => try sshClientArgs(alloc, argv[1..]),
        .mosh => mosh: {
            const destination = try moshDestination(alloc, argv) orelse
                break :mosh null;
            const result = try alloc.alloc([]const u8, 1);
            result[0] = destination;
            break :mosh result;
        },
        .et, .telnet => null,
    };
}

/// ssh options that take a value.
const ssh_value_options = "BbcDEeFIiJLlmOoPpQRSWw";

/// ssh options worth keeping to connect the same way: where to connect,
/// as whom, with which keys and config.
const ssh_kept_options = "46BbcCFIiJlmopPS";

fn sshClientArgs(
    alloc: Allocator,
    args: []const []const u8,
) Allocator.Error!?[]const []const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    var destination: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            if (destination == null and i + 1 < args.len) destination = args[i + 1];
            break;
        }

        if (arg.len < 2 or arg[0] != '-') {
            // The first word that isn't an option is the destination.
            // ssh reads options after it too, until the remote command.
            if (destination != null) break;
            destination = arg;
            continue;
        }

        // Options may be grouped ("-xa") and values may be attached
        // ("-p2222", "-oUser=me").
        var j: usize = 1;
        while (j < arg.len) : (j += 1) {
            const option = arg[j .. j + 1];
            const keep = std.mem.indexOfScalar(u8, ssh_kept_options, option[0]) != null;
            if (std.mem.indexOfScalar(u8, ssh_value_options, option[0]) == null) {
                if (keep) try result.append(alloc, try std.fmt.allocPrint(alloc, "-{s}", .{option}));
                continue;
            }

            const value = if (j + 1 < arg.len) arg[j + 1 ..] else value: {
                i += 1;
                if (i >= args.len) return null;
                break :value args[i];
            };
            if (keep) {
                try result.append(alloc, try std.fmt.allocPrint(alloc, "-{s}", .{option}));
                try result.append(alloc, value);
            }
            break;
        }
    }

    const dest = destination orelse return null;
    if (dest.len == 0 or dest[0] == '-') return null;
    try result.append(alloc, dest);
    return result.items;
}

/// The host mosh connected to through ssh. See `sshArgs`.
fn moshDestination(
    alloc: Allocator,
    argv: []const []const u8,
) Allocator.Error!?[]const u8 {
    // mosh runs mosh-client as: mosh-client "-# <arguments> |" IP PORT
    for (argv[1..]) |arg| {
        if (!std.mem.startsWith(u8, arg, "-#")) continue;
        var line = std.mem.trim(u8, arg[2..], " ");
        if (std.mem.endsWith(u8, line, "|")) line = std.mem.trimEnd(u8, line[0 .. line.len - 1], " ");

        var words: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        while (it.next()) |word| try words.append(alloc, word);
        return moshArgsDestination(words.items);
    }

    // The mosh script itself, before it starts mosh-client.
    if (std.mem.eql(u8, std.fs.path.basename(argv[0]), "mosh")) {
        return moshArgsDestination(argv[1..]);
    }

    return null;
}

/// The destination in mosh's own arguments: the first word that isn't an
/// option.
fn moshArgsDestination(args: []const []const u8) ?[]const u8 {
    const value_options = std.StaticStringMap(void).initComptime(.{
        .{"--client"},
        .{"--server"},
        .{"--predict"},
        .{"--port"},
        .{"-p"},
        .{"--ssh"},
        .{"--bind-server"},
        .{"--family"},
        .{"--experimental-remote-ip"},
    });

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            return if (i + 1 < args.len) args[i + 1] else null;
        }
        if (arg.len > 1 and arg[0] == '-') {
            if (std.mem.indexOfScalar(u8, arg, '=') == null and value_options.has(arg)) i += 1;
            continue;
        }
        return arg;
    }

    return null;
}

test "sshArgs ssh" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const cases = [_]struct {
        argv: []const []const u8,
        expect: ?[]const []const u8,
    }{
        .{ .argv = &.{ "ssh", "spark3" }, .expect = &.{"spark3"} },
        .{
            .argv = &.{ "ssh", "-p", "2222", "-i", "~/.ssh/key", "me@host", "tmux", "a" },
            .expect = &.{ "-p", "2222", "-i", "~/.ssh/key", "me@host" },
        },
        // Forwarding and tty options are dropped, attached values kept.
        .{
            .argv = &.{ "ssh", "-tt", "-L", "8080:localhost:80", "-oUser=me", "-xA4", "host" },
            .expect = &.{ "-o", "User=me", "-4", "host" },
        },
        // Options after the destination, as ssh allows.
        .{
            .argv = &.{ "ssh", "-x", "-a", "-oClearAllForwardings=yes", "dev@10.10.10.11", "-p", "22", "-s", "sftp" },
            .expect = &.{ "-o", "ClearAllForwardings=yes", "-p", "22", "dev@10.10.10.11" },
        },
        .{ .argv = &.{ "ssh", "-J", "jump", "--", "host" }, .expect = &.{ "-J", "jump", "host" } },
        .{ .argv = &.{"ssh"}, .expect = null },
        .{ .argv = &.{ "ssh", "-p" }, .expect = null },
    };

    for (cases) |case| {
        const result = try sshArgs(alloc, .ssh, case.argv);
        if (case.expect) |expect| {
            const actual = result orelse return error.TestUnexpectedNull;
            try testing.expectEqual(expect.len, actual.len);
            for (expect, actual) |e, a| try testing.expectEqualStrings(e, a);
        } else {
            try testing.expect(result == null);
        }
    }
}

test "sshArgs mosh" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const cases = [_]struct {
        argv: []const []const u8,
        expect: ?[]const u8,
    }{
        .{ .argv = &.{ "mosh-client", "-# spark3 |", "100.83.203.119", "60002" }, .expect = "spark3" },
        .{ .argv = &.{ "/opt/homebrew/bin/mosh-client", "-# me@mini -- tmux new -A |", "1.2.3.4", "60001" }, .expect = "me@mini" },
        .{ .argv = &.{ "mosh-client", "-# --ssh=ssh -p 2222 --predict always host |", "1.2.3.4", "60001" }, .expect = "host" },
        .{ .argv = &.{ "mosh-client", "-# -- host |", "1.2.3.4", "60001" }, .expect = "host" },
        .{ .argv = &.{ "mosh", "--port=60000", "host" }, .expect = "host" },
        // Started by hand, the host isn't known.
        .{ .argv = &.{ "mosh-client", "1.2.3.4", "60001" }, .expect = null },
        .{ .argv = &.{ "mosh-client", "-# |", "1.2.3.4", "60001" }, .expect = null },
    };

    for (cases) |case| {
        const result = try sshArgs(alloc, .mosh, case.argv);
        if (case.expect) |expect| {
            const actual = result orelse return error.TestUnexpectedNull;
            try testing.expectEqual(1, actual.len);
            try testing.expectEqualStrings(expect, actual[0]);
        } else {
            try testing.expect(result == null);
        }
    }

    try testing.expect(try sshArgs(alloc, .et, &.{ "et", "host" }) == null);
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
