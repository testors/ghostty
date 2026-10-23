//! Helpers for expanding tab title format strings.

const std = @import("std");
const global = @import("global.zig");
const compat_file = @import("lib/compat/file.zig");

/// Expand a tab title format string.
///
/// Supported variables:
///   * `%d` - current working directory
///   * `%c` - terminal title (usually the running command)
///   * `%g` - git branch
///   * `%%` - literal `%`
///
/// Unknown variables are left as-is.
pub fn expand(
    alloc: std.mem.Allocator,
    format: []const u8,
    pwd: ?[]const u8,
    terminal_title: ?[]const u8,
    git_branch: ?[]const u8,
) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(alloc);

    var i: usize = 0;
    while (i < format.len) {
        if (format[i] == '%' and i + 1 < format.len) {
            const c = format[i + 1];
            switch (c) {
                'd' => if (pwd) |v| try buf.appendSlice(alloc, v),
                'c' => if (terminal_title) |v| try buf.appendSlice(alloc, v),
                'g' => if (git_branch) |v| try buf.appendSlice(alloc, v),
                '%' => try buf.append(alloc, '%'),
                else => {
                    try buf.append(alloc, '%');
                    try buf.append(alloc, c);
                },
            }
            i += 2;
        } else {
            try buf.append(alloc, format[i]);
            i += 1;
        }
    }

    return buf.toOwnedSlice(alloc);
}

/// Return the current git branch for the given working directory, if any.
///
/// This walks up the directory tree looking for a `.git` directory or file.
/// For a `.git` file (worktrees), the referenced git directory is used.
/// If HEAD is detached, the abbreviated commit hash is returned.
pub fn gitBranch(alloc: std.mem.Allocator, pwd: []const u8) !?[]const u8 {
    var current = try alloc.dupe(u8, pwd);
    defer alloc.free(current);

    while (true) {
        const git_path = try std.fs.path.join(alloc, &.{ current, ".git" });
        defer alloc.free(git_path);

        if (std.Io.Dir.cwd().statFile(global.io(), git_path, .{})) |stat| {
            if (stat.kind == .directory) {
                const head_path = try std.fs.path.join(alloc, &.{ git_path, "HEAD" });
                defer alloc.free(head_path);
                return try readHead(alloc, head_path);
            }

            const file = std.Io.Dir.cwd().openFile(global.io(), git_path, .{}) catch return null;
            defer file.close(global.io());

            const contents = compat_file.readToEndAlloc(file, alloc, 4096) catch return null;
            defer alloc.free(contents);

            const trimmed = std.mem.trim(u8, contents, " \t\r\n");
            if (std.mem.startsWith(u8, trimmed, "gitdir: ")) {
                const gitdir = trimmed["gitdir: ".len..];
                const resolved = if (std.fs.path.isAbsolute(gitdir))
                    try alloc.dupe(u8, gitdir)
                else
                    try std.fs.path.join(alloc, &.{ current, gitdir });
                defer alloc.free(resolved);

                const head_path = try std.fs.path.join(alloc, &.{ resolved, "HEAD" });
                defer alloc.free(head_path);
                return try readHead(alloc, head_path);
            }

            return null;
        } else |_| {}

        const parent = std.fs.path.dirname(current) orelse return null;
        if (std.mem.eql(u8, parent, current)) return null;

        const next = try alloc.dupe(u8, parent);
        alloc.free(current);
        current = next;
    }
}

fn readHead(alloc: std.mem.Allocator, path: []const u8) !?[]const u8 {
    const file = std.Io.Dir.cwd().openFile(global.io(), path, .{}) catch return null;
    defer file.close(global.io());

    const contents = compat_file.readToEndAlloc(file, alloc, 4096) catch return null;
    defer alloc.free(contents);

    const trimmed = std.mem.trim(u8, contents, " \t\r\n");

    if (std.mem.startsWith(u8, trimmed, "ref: refs/heads/")) {
        return try alloc.dupe(u8, trimmed["ref: refs/heads/".len..]);
    }

    if (trimmed.len >= 7) {
        return try alloc.dupe(u8, trimmed[0..7]);
    }

    return null;
}

test "expand" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const result = try expand(
        alloc,
        "%g — %d (%c) %%",
        "/home/user/project",
        "vim",
        "main",
    );
    defer alloc.free(result);

    try testing.expectEqualStrings("main — /home/user/project (vim) %", result);
}

test "expand unknown" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const result = try expand(alloc, "%x %", null, null, null);
    defer alloc.free(result);

    try testing.expectEqualStrings("%x %", result);
}
