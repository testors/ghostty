//! Format-preserving editing of Ghostty configuration files.
//!
//! The settings editor changes configuration by editing individual
//! lines of the user's configuration files. Every line that isn't
//! touched is written back byte-for-byte: comments, blank lines,
//! ordering, line endings and a leading byte order mark are kept.
//!
//! Lines are addressed by their 1-indexed line number, matching the
//! numbering used by `cli.args.LineIterator` (and so the locations
//! recorded in a `Trace`).
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const global = @import("../global.zig");
const whitespace = @import("../cli/args.zig").whitespace;

const log = std.log.scoped(.config_edit);

/// The comment written above the first entry the settings editor
/// appends to a file.
pub const marker = "# Added by Ghostty Settings";

pub const Error = error{
    /// The line at the given location doesn't hold the expected key.
    /// The file was most likely changed by something else since it
    /// was last loaded.
    FileChanged,
} || Allocator.Error;

/// A configuration file loaded as a list of lines.
pub const Document = struct {
    /// Allocator for all document memory. Must be an arena-like
    /// allocator since individual lines are never freed.
    alloc: Allocator,

    /// The lines of the file without the "\n" line ending. A line
    /// that ended with "\r\n" keeps its "\r" so files with mixed line
    /// endings are written back unchanged.
    lines: std.ArrayList([]const u8) = .empty,

    /// The line ending used by new lines ("\n" or "\r\n").
    eol: []const u8 = "\n",

    /// True if the file ended with a line ending.
    trailing_newline: bool = true,

    /// True if the file started with a UTF-8 byte order mark.
    bom: bool = false,

    const bom_bytes = "\xef\xbb\xbf";

    /// Parse a document from the raw file contents.
    pub fn parse(alloc: Allocator, contents: []const u8) Allocator.Error!Document {
        var result: Document = .{ .alloc = alloc };
        var data = contents;

        if (std.mem.startsWith(u8, data, bom_bytes)) {
            result.bom = true;
            data = data[bom_bytes.len..];
        }

        if (data.len == 0) return result;

        // Use the line ending style of the first line.
        if (std.mem.indexOfScalar(u8, data, '\n')) |idx| {
            if (idx > 0 and data[idx - 1] == '\r') result.eol = "\r\n";
        }

        result.trailing_newline = data[data.len - 1] == '\n';
        const body = if (result.trailing_newline) data[0 .. data.len - 1] else data;

        var it = std.mem.splitScalar(u8, body, '\n');
        while (it.next()) |raw| {
            try result.lines.append(alloc, try alloc.dupe(u8, raw));
        }

        return result;
    }

    /// Load the document at the given absolute path. A missing file
    /// results in an empty document.
    pub fn load(alloc: Allocator, path: []const u8) !Document {
        const contents = std.Io.Dir.cwd().readFileAlloc(
            global.io(),
            path,
            alloc,
            .limited(16 * 1024 * 1024),
        ) catch |err| switch (err) {
            error.FileNotFound => return .{ .alloc = alloc },
            else => return err,
        };

        return try parse(alloc, contents);
    }

    /// Write the document to the given writer.
    pub fn write(self: *const Document, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.bom) try writer.writeAll(bom_bytes);
        for (self.lines.items, 0..) |line, i| {
            try writer.writeAll(line);
            const last = i == self.lines.items.len - 1;
            if (!last or self.trailing_newline) try writer.writeByte('\n');
        }
    }

    /// Returns the full contents as a newly allocated string.
    pub fn toOwnedSlice(self: *const Document, alloc: Allocator) Allocator.Error![]u8 {
        var buf: std.Io.Writer.Allocating = .init(alloc);
        errdefer buf.deinit();
        self.write(&buf.writer) catch return error.OutOfMemory;
        return try buf.toOwnedSlice();
    }

    /// Returns the configuration key on the given 1-indexed line or
    /// null if the line isn't a configuration entry.
    pub fn keyAt(self: *const Document, line: usize) ?[]const u8 {
        if (line == 0 or line > self.lines.items.len) return null;
        return entryKey(self.lines.items[line - 1]);
    }

    /// Returns the 1-indexed line of the last entry for the key.
    pub fn lastLineOf(self: *const Document, key: []const u8) ?usize {
        var i: usize = self.lines.items.len;
        while (i > 0) : (i -= 1) {
            const k = entryKey(self.lines.items[i - 1]) orelse continue;
            if (std.mem.eql(u8, k, key)) return i;
        }

        return null;
    }

    /// Returns the 1-indexed lines of every entry for the key.
    pub fn linesOf(
        self: *const Document,
        alloc: Allocator,
        key: []const u8,
    ) Allocator.Error![]usize {
        var result: std.ArrayList(usize) = .empty;
        errdefer result.deinit(alloc);
        for (self.lines.items, 1..) |line, i| {
            const k = entryKey(line) orelse continue;
            if (std.mem.eql(u8, k, key)) try result.append(alloc, i);
        }

        return try result.toOwnedSlice(alloc);
    }

    fn checkKey(self: *const Document, line: usize, key: []const u8) Error!void {
        const actual = self.keyAt(line) orelse return error.FileChanged;
        if (!std.mem.eql(u8, actual, key)) return error.FileChanged;
    }

    /// Replace the value of the entry on the given line. The line must
    /// currently hold an entry for `key`.
    pub fn replace(
        self: *Document,
        line: usize,
        key: []const u8,
        value: ?[]const u8,
    ) Error!void {
        try self.checkKey(line, key);
        self.lines.items[line - 1] = try self.newLine(key, value);
    }

    /// Remove the entry on the given line. The line must currently hold
    /// an entry for `key`.
    pub fn remove(self: *Document, line: usize, key: []const u8) Error!void {
        try self.checkKey(line, key);
        _ = self.lines.orderedRemove(line - 1);
    }

    /// Insert a new entry directly after the given line.
    pub fn insertAfter(
        self: *Document,
        line: usize,
        key: []const u8,
        value: ?[]const u8,
    ) Allocator.Error!void {
        const idx = @min(line, self.lines.items.len);
        try self.lines.insert(self.alloc, idx, try self.newLine(key, value));
    }

    /// Append a new entry to the end of the file. The first time the
    /// settings editor appends to a file, a marker comment is written
    /// above the entry so the user knows where it came from.
    pub fn append(
        self: *Document,
        key: []const u8,
        value: ?[]const u8,
    ) Allocator.Error!void {
        const cr: []const u8 = if (self.crlf()) "\r" else "";
        if (!self.hasMarker()) {
            if (self.lines.items.len > 0) {
                const last = self.lines.items[self.lines.items.len - 1];
                if (std.mem.trim(u8, last, whitespace ++ "\r").len > 0) {
                    try self.lines.append(self.alloc, cr);
                }
            }

            try self.lines.append(self.alloc, if (cr.len > 0) marker ++ "\r" else marker);
        }

        try self.lines.append(self.alloc, try self.newLine(key, value));
        self.trailing_newline = true;
    }

    /// Add an entry next to the existing entries for the same key if
    /// there are any, otherwise append it to the end of the file.
    pub fn add(
        self: *Document,
        key: []const u8,
        value: ?[]const u8,
    ) Allocator.Error!void {
        if (self.lastLineOf(key)) |line| {
            try self.insertAfter(line, key, value);
        } else {
            try self.append(key, value);
        }
    }

    fn hasMarker(self: *const Document) bool {
        for (self.lines.items) |line| {
            const trimmed = std.mem.trim(u8, line, whitespace ++ "\r");
            if (std.mem.eql(u8, trimmed, marker)) return true;
        }

        return false;
    }

    fn crlf(self: *const Document) bool {
        return std.mem.eql(u8, self.eol, "\r\n");
    }

    /// Format a new line using the document's line ending.
    fn newLine(
        self: *const Document,
        key: []const u8,
        value: ?[]const u8,
    ) Allocator.Error![]const u8 {
        const line = try formatLine(self.alloc, key, value);
        if (!self.crlf()) return line;
        return try std.mem.concat(self.alloc, u8, &.{ line, "\r" });
    }

    /// Save the document to the given path atomically. If the path is a
    /// symbolic link, the file it points to is replaced and the link is
    /// kept (dotfile managers often link configuration files). The
    /// permissions of an existing file are kept.
    pub fn save(self: *const Document, path: []const u8) !void {
        const io = global.io();

        // Resolve symlinks so we replace the real file. If the file
        // doesn't exist yet we write to the path as given.
        var real_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const real_path: []const u8 = real: {
            const len = std.Io.Dir.realPathFileAbsolute(
                io,
                path,
                &real_buf,
            ) catch break :real path;
            break :real real_buf[0..len];
        };

        const dir_path = std.fs.path.dirname(real_path) orelse return error.InvalidPath;
        const basename = std.fs.path.basename(real_path);
        try std.Io.Dir.cwd().createDirPath(io, dir_path);
        var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{});
        defer dir.close(io);

        // Keep the existing permissions if we can.
        const permissions: std.Io.File.Permissions = perms: {
            const stat = dir.statFile(io, basename, .{}) catch break :perms .default_file;
            break :perms stat.permissions;
        };

        var buf: [4096]u8 = undefined;
        var atomic_file = try dir.createFileAtomic(io, basename, .{
            .permissions = permissions,
            .replace = true,
        });
        defer atomic_file.deinit(io);
        var file_writer = atomic_file.file.writer(io, &buf);
        try self.write(&file_writer.interface);
        try file_writer.interface.flush();
        try atomic_file.replace(io);
    }
};

/// Returns the key of a configuration line or null if the line is
/// blank or a comment. This mirrors `cli.args.LineIterator`.
pub fn entryKey(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, whitespace ++ "\r");
    if (trimmed.len == 0 or trimmed[0] == '#') return null;
    const end = std.mem.indexOfScalar(u8, trimmed, '=') orelse trimmed.len;
    const key = std.mem.trim(u8, trimmed[0..end], whitespace);
    if (key.len == 0) return null;
    return key;
}

/// Format a configuration line. A null value writes the key alone,
/// which is how boolean flags can be enabled. Values are quoted when
/// the configuration parser would otherwise change them (surrounding
/// whitespace or surrounding quotes).
pub fn formatLine(
    alloc: Allocator,
    key: []const u8,
    value: ?[]const u8,
) Allocator.Error![]const u8 {
    const v = value orelse return try alloc.dupe(u8, key);
    if (needsQuotes(v)) {
        return try std.fmt.allocPrint(alloc, "{s} = \"{s}\"", .{ key, v });
    }

    return try std.fmt.allocPrint(alloc, "{s} = {s}", .{ key, v });
}

fn needsQuotes(value: []const u8) bool {
    if (value.len == 0) return false;
    const trimmed = std.mem.trim(u8, value, whitespace);
    if (trimmed.len != value.len) return true;
    return value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"';
}

test "parse and write round trip" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const inputs = [_][]const u8{
        "",
        "a = 1",
        "a = 1\n",
        "# comment\n\na = 1\r\nb = 2\r\n",
        "\xef\xbb\xbfa = 1\n",
        "  font-family = Foo  \n\n\n",
    };

    for (inputs) |input| {
        const doc = try Document.parse(alloc, input);
        const output = try doc.toOwnedSlice(alloc);
        try testing.expectEqualStrings(input, output);
    }
}

test "line numbers match the config parser" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const doc = try Document.parse(alloc,
        \\# My config
        \\font-family = A
        \\
        \\  font-size=13
        \\maximize
        \\# x = 1
    );

    try testing.expect(doc.keyAt(1) == null);
    try testing.expectEqualStrings("font-family", doc.keyAt(2).?);
    try testing.expect(doc.keyAt(3) == null);
    try testing.expectEqualStrings("font-size", doc.keyAt(4).?);
    try testing.expectEqualStrings("maximize", doc.keyAt(5).?);
    try testing.expect(doc.keyAt(6) == null);
    try testing.expect(doc.keyAt(7) == null);
    try testing.expectEqual(@as(?usize, 4), doc.lastLineOf("font-size"));
}

test "replace keeps other lines" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var doc = try Document.parse(alloc, "# hi\nfont-size = 13\n# bye\n");
    try doc.replace(2, "font-size", "14");
    try testing.expectEqualStrings(
        "# hi\nfont-size = 14\n# bye\n",
        try doc.toOwnedSlice(alloc),
    );

    try testing.expectError(error.FileChanged, doc.replace(1, "font-size", "1"));
    try testing.expectError(error.FileChanged, doc.replace(3, "font-size", "1"));
    try testing.expectError(error.FileChanged, doc.replace(9, "font-size", "1"));
}

test "crlf files keep crlf" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var doc = try Document.parse(alloc, "a = 1\r\nb = 2\r\n");
    try doc.replace(1, "a", "3");
    try doc.append("c", "4");
    try testing.expectEqualStrings(
        "a = 3\r\nb = 2\r\n\r\n" ++ marker ++ "\r\nc = 4\r\n",
        try doc.toOwnedSlice(alloc),
    );
}

test "remove" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var doc = try Document.parse(alloc, "a = 1\nb = 2\nc = 3");
    try doc.remove(2, "b");
    try testing.expectEqualStrings("a = 1\nc = 3", try doc.toOwnedSlice(alloc));
    try testing.expectError(error.FileChanged, doc.remove(2, "b"));
}

test "append writes the marker once" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var doc = try Document.parse(alloc, "a = 1");
    try doc.append("b", "2");
    try doc.append("c", null);
    try testing.expectEqualStrings(
        "a = 1\n\n" ++ marker ++ "\nb = 2\nc\n",
        try doc.toOwnedSlice(alloc),
    );

    var empty = try Document.parse(alloc, "");
    try empty.append("b", "2");
    try testing.expectEqualStrings(
        marker ++ "\nb = 2\n",
        try empty.toOwnedSlice(alloc),
    );
}

test "add groups repeated keys" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var doc = try Document.parse(alloc, "keybind = a=b\nfont-size = 1\n");
    try doc.add("keybind", "c=d");
    try testing.expectEqualStrings(
        "keybind = a=b\nkeybind = c=d\nfont-size = 1\n",
        try doc.toOwnedSlice(alloc),
    );
}

test "formatLine quoting" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try testing.expectEqualStrings("a = b", try formatLine(alloc, "a", "b"));
    try testing.expectEqualStrings("a = ", try formatLine(alloc, "a", ""));
    try testing.expectEqualStrings("a", try formatLine(alloc, "a", null));
    try testing.expectEqualStrings("a = \" x\"", try formatLine(alloc, "a", " x"));
    try testing.expectEqualStrings("a = \"\"q\"\"", try formatLine(alloc, "a", "\"q\""));
}

test "save keeps symlinks" {
    if (comptime builtin.target.os.tag == .windows) return error.SkipZigTest;

    const testing = std.testing;
    const io = global.io();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);
    const root = root_buf[0..root_len];

    try tmp.dir.writeFile(io, .{ .sub_path = "real", .data = "a = 1\n" });
    try tmp.dir.symLink(io, "real", "link", .{});

    const link_path = try std.fs.path.join(alloc, &.{ root, "link" });
    var doc = try Document.load(alloc, link_path);
    try doc.replace(1, "a", "2");
    try doc.save(link_path);

    // The link is still a link and the real file was updated.
    var link_buf: [64]u8 = undefined;
    const target_len = try tmp.dir.readLink(io, "link", &link_buf);
    try testing.expectEqualStrings("real", link_buf[0..target_len]);
    const contents = try tmp.dir.readFileAlloc(io, "real", alloc, .limited(1024));
    try testing.expectEqualStrings("a = 2\n", contents);

    // Saving a new file creates it.
    const new_path = try std.fs.path.join(alloc, &.{ root, "sub", "new" });
    var new_doc = try Document.load(alloc, new_path);
    try new_doc.append("b", "3");
    try new_doc.save(new_path);
    const new_contents = try tmp.dir.readFileAlloc(io, "sub/new", alloc, .limited(1024));
    try testing.expectEqualStrings(marker ++ "\nb = 3\n", new_contents);
}
