//! Editor is the model behind settings UIs. It loads the configuration
//! the same way the app does while recording where every entry came
//! from, and it changes settings by editing the user's configuration
//! files in place (see `edit_file.zig`).
//!
//! The rules for writing a change:
//!
//!   * A key that is already set has the line that sets it (the last
//!     one, for scalar keys) updated in place, in whichever file it is
//!     in, including files loaded with `config-file`.
//!   * A key that isn't set yet is appended to the main config file.
//!   * Resetting a key removes its lines so the default applies.
//!   * Every value is validated with the real configuration parser
//!     before anything is written.
//!
//! After each change the editor reloads so its view always matches
//! the files on disk. Applying changes to a running app is up to the
//! caller (usually a normal configuration reload).
const Editor = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const global = @import("../global.zig");
const cli = @import("../cli.zig");
const terminal_color = @import("../terminal/color.zig");
const Config = @import("Config.zig");
const Trace = @import("Trace.zig");
const conditional = @import("conditional.zig");
const edit = @import("edit.zig");
const edit_file = @import("edit_file.zig");
const schema = @import("schema.zig");
const themepkg = @import("theme.zig");
const Document = edit_file.Document;

const log = std.log.scoped(.config_editor);

pub const Options = struct {
    /// Load only this file instead of the default configuration files.
    /// This also becomes the file new settings are written to.
    path: ?[]const u8 = null,

    /// Load CLI arguments, like the app does.
    cli_args: bool = true,

    /// The color scheme used to resolve `theme = light:...,dark:...`.
    theme: conditional.State.Theme = .light,
};

pub const Error = error{
    /// The key doesn't exist.
    UnknownKey,

    /// The value was rejected by the configuration parser. The message
    /// explains why.
    InvalidValue,

    /// The file changed since it was loaded so the edit wasn't made.
    /// The editor reloaded; retrying will use the new contents.
    FileChanged,
};

gpa: Allocator,
options: Options,

/// The file new settings are appended to.
primary_path: []const u8,

/// Where every loaded entry came from.
trace: Trace,

/// The finalized configuration as of the last load.
config: ?Config = null,

/// Explanation for the last failed operation.
message: std.ArrayList(u8) = .empty,

pub fn create(gpa: Allocator, options: Options) !*Editor {
    const self = try gpa.create(Editor);
    errdefer gpa.destroy(self);

    const path: ?[]const u8 = if (options.path) |p| try gpa.dupe(u8, p) else null;
    errdefer if (path) |p| gpa.free(p);
    const primary = if (path) |p| try gpa.dupe(u8, p) else try edit.preferredPath(gpa);
    errdefer gpa.free(primary);

    self.* = .{
        .gpa = gpa,
        .options = .{
            .path = path,
            .cli_args = options.cli_args,
            .theme = options.theme,
        },
        .primary_path = primary,
        .trace = .init(gpa),
    };
    errdefer self.trace.deinit();

    try self.reload();
    return self;
}

pub fn destroy(self: *Editor) void {
    const gpa = self.gpa;
    if (self.config) |*c| c.deinit();
    self.trace.deinit();
    self.message.deinit(gpa);
    if (self.options.path) |p| gpa.free(p);
    gpa.free(self.primary_path);
    gpa.destroy(self);
}

/// The message explaining the last error, if there is one.
pub fn lastMessage(self: *const Editor) []const u8 {
    return self.message.items;
}

fn setMessage(self: *Editor, comptime fmt: []const u8, args: anytype) void {
    self.message.clearRetainingCapacity();
    self.message.print(self.gpa, fmt, args) catch {};
}

/// Reload everything from disk.
pub fn reload(self: *Editor) !void {
    self.trace.clear();
    const cfg = try self.load(&self.trace, null);
    if (self.config) |*old| old.deinit();
    self.config = cfg;
}

/// Change the color scheme used to resolve light/dark themes.
pub fn setTheme(self: *Editor, theme: conditional.State.Theme) !void {
    if (self.options.theme == theme) return;
    self.options.theme = theme;
    try self.reload();
}

/// Load a finalized configuration the same way the app does. If
/// `override` is set (an argument such as `--theme=Foo`) it is applied
/// last, on top of everything else.
fn load(self: *Editor, trace: ?*Trace, override: ?[]const u8) !Config {
    const gpa = self.gpa;
    var cfg = try Config.default(gpa);
    errdefer cfg.deinit();
    cfg._conditional_state.theme = self.options.theme;
    cfg._trace = trace;

    if (self.options.path) |path| {
        _ = cfg.loadOptionalFile(gpa, path);
    } else {
        try cfg.loadDefaultFiles(gpa);
    }

    if (self.options.cli_args) try cfg.loadCliArgs(gpa);
    try cfg.loadRecursiveFiles(gpa);
    cfg._trace = null;

    if (override) |arg| {
        const args = [_][]const u8{arg};
        var it: cli.args.SliceIterator = .{ .slice = &args };
        try cfg.loadIter(gpa, &it);
    }

    try cfg.finalize();
    return cfg;
}

/// Validate a value for a key with the configuration parser. Returns
/// null if the value is valid or a message explaining the problem.
pub fn validate(
    self: *Editor,
    alloc: Allocator,
    key: []const u8,
    value: ?[]const u8,
) !?[]const u8 {
    if (schema.get(key) == null) {
        return try std.fmt.allocPrint(alloc, "unknown setting \"{s}\"", .{key});
    }

    if (value) |v| {
        // A line break would write a second, unvalidated line.
        if (std.mem.indexOfAny(u8, v, "\r\n") != null) {
            return try alloc.dupe(u8, "values can't contain line breaks");
        }
    }

    var cfg = try Config.default(self.gpa);
    defer cfg.deinit();
    const arg = if (value) |v|
        try std.fmt.allocPrint(alloc, "--{s}={s}", .{ key, v })
    else
        try std.fmt.allocPrint(alloc, "--{s}", .{key});
    const args = [_][]const u8{arg};
    var it: cli.args.SliceIterator = .{ .slice = &args };
    try cfg.loadIter(self.gpa, &it);

    const diags = cfg._diagnostics.items();
    if (diags.len == 0) return null;
    return try alloc.dupe(u8, diags[0].message);
}

fn checkValid(self: *Editor, key: []const u8, value: ?[]const u8) !void {
    var arena: ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    if (try self.validate(arena.allocator(), key, value)) |msg| {
        self.setMessage("{s}: {s}", .{ key, msg });
        return if (schema.get(key) == null) error.UnknownKey else error.InvalidValue;
    }
}

fn schemaEntry(self: *Editor, key: []const u8) !*const schema.Entry {
    return schema.get(key) orelse {
        self.setMessage("unknown setting \"{s}\"", .{key});
        return error.UnknownKey;
    };
}

pub const FileLine = struct {
    path: []const u8,
    line: usize,
};

/// An entry for a key in a configuration file.
pub const FileEntry = struct {
    /// The value, or null for a bare key (a flag set to true).
    value: ?[]const u8,
    path: []const u8,
    line: usize,
};

/// The effective values of a key, formatted as configuration values.
/// Repeatable keys have one value per entry.
pub fn effectiveValues(self: *const Editor, alloc: Allocator, key: []const u8) ![]const []const u8 {
    const cfg = if (self.config) |*c| c else return &.{};
    return try schema.formatValues(alloc, cfg, key);
}

/// The effective value of a scalar key ("" if unset).
pub fn effectiveValue(self: *const Editor, alloc: Allocator, key: []const u8) ![]const u8 {
    const list = try self.effectiveValues(alloc, key);
    return if (list.len > 0) list[0] else "";
}

/// True if a configuration file sets the key.
pub fn isModified(self: *const Editor, key: []const u8) bool {
    return self.lastFileEntry(key) != null;
}

/// Every entry for the key in configuration files, in load order. The
/// returned memory references the editor's trace and is valid until the
/// next change or reload.
pub fn fileEntries(
    self: *const Editor,
    alloc: Allocator,
    key: []const u8,
) Allocator.Error![]FileEntry {
    var result: std.ArrayList(FileEntry) = .empty;
    for (self.trace.entries.items) |*entry| {
        if (!std.mem.eql(u8, entry.key, key)) continue;
        switch (entry.location) {
            .file => |f| try result.append(alloc, .{
                .value = entry.value,
                .path = f.path,
                .line = f.line,
            }),
            .cli => {},
        }
    }

    return try result.toOwnedSlice(alloc);
}

/// The last entry for the key that came from a file. This is the entry
/// that determines the value of scalar keys.
pub fn lastFileEntry(self: *const Editor, key: []const u8) ?FileLine {
    var i: usize = self.trace.entries.items.len;
    while (i > 0) {
        i -= 1;
        const entry = &self.trace.entries.items[i];
        if (!std.mem.eql(u8, entry.key, key)) continue;
        switch (entry.location) {
            .file => |f| return .{ .path = f.path, .line = f.line },
            .cli => {},
        }
    }

    return null;
}

/// The files that set the key, in load order, without duplicates.
fn filesSetting(
    self: *const Editor,
    alloc: Allocator,
    key: []const u8,
) Allocator.Error![]const []const u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    for (self.trace.entries.items) |*entry| {
        if (!std.mem.eql(u8, entry.key, key)) continue;
        const f = switch (entry.location) {
            .file => |f| f,
            .cli => continue,
        };
        for (paths.items) |p| {
            if (std.mem.eql(u8, p, f.path)) break;
        } else try paths.append(alloc, f.path);
    }

    return try paths.toOwnedSlice(alloc);
}

/// True if the effective value of the key is set by a CLI argument
/// (so file edits won't change it until Ghostty is launched without it).
pub fn isSetByCli(self: *const Editor, key: []const u8) bool {
    const entry = self.trace.last(key) orelse return false;
    return entry.location == .cli;
}

/// Turn a document edit error into our error with a message, reloading
/// so the next attempt sees the new file contents.
fn editFailed(self: *Editor, err: anyerror, path: []const u8) anyerror {
    if (err == error.FileChanged) {
        self.setMessage("{s} was changed by another program, try again", .{path});
        self.reload() catch {};
    }

    return err;
}

/// Set a key to a single value. For repeatable keys this replaces all
/// of their values (see `setList`).
pub fn set(self: *Editor, key: []const u8, value: ?[]const u8) !void {
    const entry = try self.schemaEntry(key);
    if (entry.repeatable) {
        if (value) |v| {
            const one = [_][]const u8{v};
            return try self.setList(key, &one);
        }

        return try self.setList(key, &.{});
    }

    try self.checkValid(key, value);

    var arena: ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    if (self.lastFileEntry(key)) |target| {
        var doc = try Document.load(alloc, target.path);
        doc.replace(target.line, key, value) catch |err|
            return self.editFailed(err, target.path);
        try doc.save(target.path);
    } else {
        var doc = try Document.load(alloc, self.primary_path);
        try doc.append(key, value);
        try doc.save(self.primary_path);
    }

    try self.reload();
}

/// Replace the values of a repeatable key, so that the key's entries in
/// configuration files are exactly `values`. The values are written where
/// the first entry for the key is (or appended to the main file) and the
/// key's entries in every other file are removed.
pub fn setList(self: *Editor, key: []const u8, values: []const []const u8) !void {
    _ = try self.schemaEntry(key);
    for (values) |v| try self.checkValid(key, v);

    var arena: ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const setting = try self.filesSetting(alloc, key);
    const paths: []const []const u8 = if (setting.len > 0)
        setting
    else
        try alloc.dupe([]const u8, &.{self.primary_path});

    // Edit every file before saving any, so that a file which changed
    // since the last reload fails the change without writing anything.
    const docs = try alloc.alloc(Document, paths.len);
    for (paths, docs, 0..) |path, *doc, i| {
        doc.* = try Document.load(alloc, path);
        const lines = try doc.linesOf(alloc, key);

        var j: usize = lines.len;
        while (j > 0) {
            j -= 1;
            doc.remove(lines[j], key) catch |err| return self.editFailed(err, path);
        }

        if (i > 0) continue;
        if (lines.len > 0) {
            // Insert where the first entry was so the user's ordering of
            // the file is kept.
            const at = lines[0] - 1;
            for (values, 0..) |v, k| try doc.insertAfter(at + k, key, v);
        } else {
            for (values) |v| try doc.append(key, v);
        }
    }

    for (paths, docs) |path, *doc| try doc.save(path);
    try self.reload();
}

/// Add a value to a repeatable key. The entry is written to the main
/// configuration file next to existing entries for the key.
pub fn add(self: *Editor, key: []const u8, value: []const u8) !void {
    _ = try self.schemaEntry(key);
    try self.checkValid(key, value);

    var arena: ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    var doc = try Document.load(alloc, self.primary_path);
    try doc.add(key, value);
    try doc.save(self.primary_path);
    try self.reload();
}

/// Change the value of one specific entry (a line in a file).
pub fn replaceEntry(
    self: *Editor,
    key: []const u8,
    path: []const u8,
    line: usize,
    value: []const u8,
) !void {
    _ = try self.schemaEntry(key);
    try self.checkValid(key, value);

    var arena: ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    var doc = try Document.load(arena.allocator(), path);
    doc.replace(line, key, value) catch |err| return self.editFailed(err, path);
    try doc.save(path);
    try self.reload();
}

/// Remove one specific entry (a line in a file).
pub fn removeEntry(
    self: *Editor,
    key: []const u8,
    path: []const u8,
    line: usize,
) !void {
    _ = try self.schemaEntry(key);

    var arena: ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    var doc = try Document.load(arena.allocator(), path);
    doc.remove(line, key) catch |err| return self.editFailed(err, path);
    try doc.save(path);
    try self.reload();
}

/// Remove every entry for the key from the configuration files so the
/// default value applies again. CLI arguments can't be removed.
pub fn reset(self: *Editor, key: []const u8) !void {
    _ = try self.schemaEntry(key);

    var arena: ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    for (try self.filesSetting(alloc, key)) |path| {
        var doc = try Document.load(alloc, path);
        const lines = try doc.linesOf(alloc, key);
        var i: usize = lines.len;
        while (i > 0) {
            i -= 1;
            doc.remove(lines[i], key) catch |err| return self.editFailed(err, path);
        }
        try doc.save(path);
    }

    try self.reload();
}

/// A configuration with `key = value` applied on top of the current
/// configuration, without writing anything. This lets UIs preview a
/// change (such as a theme) in the running app. The caller owns the
/// returned configuration, which is allocated with the editor's
/// allocator.
pub fn preview(self: *Editor, key: []const u8, value: []const u8) !*Config {
    try self.checkValid(key, value);

    var arena: ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    const arg = try std.fmt.allocPrint(arena.allocator(), "--{s}={s}", .{ key, value });

    const cfg = try self.gpa.create(Config);
    errdefer self.gpa.destroy(cfg);
    cfg.* = try self.load(null, arg);
    return cfg;
}

/// The files that were loaded (in load order) plus the main file.
pub fn files(self: *const Editor, alloc: Allocator) ![]const []const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    errdefer result.deinit(alloc);

    try result.append(alloc, self.primary_path);
    for (self.trace.entries.items) |*entry| {
        const f = switch (entry.location) {
            .file => |f| f,
            .cli => continue,
        };
        for (result.items) |p| {
            if (std.mem.eql(u8, p, f.path)) break;
        } else try result.append(alloc, f.path);
    }

    return try result.toOwnedSlice(alloc);
}

/// Write everything a settings UI needs to show the current state:
///
///   * `primary_path`: the file new settings are written to.
///   * `files`: the configuration files that were loaded.
///   * `diagnostics`: configuration errors.
///   * `values`: the effective value of every key (as config strings).
///   * `entries`: for keys set in a file or the CLI, every entry with
///     where it came from.
pub fn writeSnapshotJson(self: *Editor, writer: *std.Io.Writer) !void {
    var arena: ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    const cfg: *const Config = if (self.config) |*c| c else return error.NotLoaded;

    var jws: std.json.Stringify = .{ .writer = writer };
    try jws.beginObject();

    try jws.objectField("primary_path");
    try jws.write(self.primary_path);

    try jws.objectField("files");
    try jws.write(try self.files(alloc));

    try jws.objectField("diagnostics");
    try jws.beginArray();
    for (cfg._diagnostics.items()) |*diag| {
        var buf: std.Io.Writer.Allocating = .init(alloc);
        try diag.format(&buf.writer);
        try jws.write(buf.written());
    }
    try jws.endArray();

    try jws.objectField("values");
    try jws.beginObject();
    for (schema.entries) |*entry| {
        if (!entry.platform.current()) continue;
        try jws.objectField(entry.key);
        try jws.write(try schema.formatValues(alloc, cfg, entry.key));
    }
    try jws.endObject();

    try jws.objectField("entries");
    try jws.beginObject();
    for (schema.entries) |*entry| {
        var any = false;
        for (self.trace.entries.items) |*t| {
            if (!std.mem.eql(u8, t.key, entry.key)) continue;
            if (!any) {
                try jws.objectField(entry.key);
                try jws.beginArray();
                any = true;
            }

            try jws.beginObject();
            try jws.objectField("value");
            try jws.write(t.value);
            switch (t.location) {
                .file => |f| {
                    try jws.objectField("path");
                    try jws.write(f.path);
                    try jws.objectField("line");
                    try jws.write(f.line);
                },
                .cli => |index| {
                    try jws.objectField("cli");
                    try jws.write(index);
                },
            }
            try jws.endObject();
        }
        if (any) try jws.endArray();
    }
    try jws.endObject();

    try jws.endObject();
}

/// A theme that can be used with the `theme` key.
pub const ThemeInfo = struct {
    name: []const u8,
    path: []const u8,
    location: themepkg.Location,
    background: terminal_color.RGB,
    foreground: terminal_color.RGB,
    palette: [16]terminal_color.RGB,

    pub fn isDark(self: *const ThemeInfo) bool {
        const r: f32 = @floatFromInt(self.background.r);
        const g: f32 = @floatFromInt(self.background.g);
        const b: f32 = @floatFromInt(self.background.b);
        const luminance = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0;
        return luminance < 0.5;
    }
};

/// List every available theme, sorted by name. Themes in the user's
/// themes directory take precedence over bundled themes with the same
/// name. All memory is allocated with `alloc`, which should be an arena.
pub fn themes(alloc: Allocator) ![]ThemeInfo {
    const io = global.io();
    var result: std.ArrayList(ThemeInfo) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;

    var it: themepkg.LocationIterator = .{ .arena_alloc = alloc };
    while (try it.next()) |loc| {
        var dir = std.Io.Dir.cwd().openDir(io, loc.dir, .{ .iterate = true }) catch continue;
        defer dir.close(io);

        var walker = dir.iterate();
        while (walker.next(io) catch null) |entry| {
            switch (entry.kind) {
                .file, .sym_link => {},
                else => continue,
            }
            if (entry.name.len == 0 or entry.name[0] == '.') continue;
            if (seen.contains(entry.name)) continue;

            const name = try alloc.dupe(u8, entry.name);
            try seen.put(alloc, name, {});
            const path = try std.fs.path.join(alloc, &.{ loc.dir, entry.name });
            const contents = dir.readFileAlloc(io, entry.name, alloc, .limited(256 * 1024)) catch continue;

            var info: ThemeInfo = .{
                .name = name,
                .path = path,
                .location = loc.location,
                .background = .{ .r = 0x28, .g = 0x2C, .b = 0x34 },
                .foreground = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF },
                .palette = terminal_color.default[0..16].*,
            };
            parseThemeColors(&info, contents);
            try result.append(alloc, info);
        }
    }

    std.mem.sortUnstable(ThemeInfo, result.items, {}, struct {
        fn lessThan(_: void, a: ThemeInfo, b: ThemeInfo) bool {
            return std.ascii.lessThanIgnoreCase(a.name, b.name);
        }
    }.lessThan);

    return result.items;
}

fn parseThemeColors(info: *ThemeInfo, contents: []const u8) void {
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw| {
        const key = edit_file.entryKey(raw) orelse continue;
        const eq = std.mem.indexOfScalar(u8, raw, '=') orelse continue;
        const value = std.mem.trim(u8, raw[eq + 1 ..], " \t\r\"");
        if (std.mem.eql(u8, key, "background")) {
            info.background = terminal_color.RGB.parse(value) catch continue;
        } else if (std.mem.eql(u8, key, "foreground")) {
            info.foreground = terminal_color.RGB.parse(value) catch continue;
        } else if (std.mem.eql(u8, key, "palette")) {
            const entry = terminal_color.parsePaletteEntry(value) catch continue;
            if (entry.index < 16) info.palette[entry.index] = entry.color;
        }
    }
}

/// Write `themes()` as JSON.
pub fn writeThemesJson(alloc: Allocator, writer: *std.Io.Writer) !void {
    var arena: ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const list = try themes(arena.allocator());

    var jws: std.json.Stringify = .{ .writer = writer };
    try jws.beginArray();
    for (list) |*t| {
        try jws.beginObject();
        try jws.objectField("name");
        try jws.write(t.name);
        try jws.objectField("path");
        try jws.write(t.path);
        try jws.objectField("location");
        try jws.write(@tagName(t.location));
        try jws.objectField("dark");
        try jws.write(t.isDark());
        try jws.objectField("background");
        try writeHex(&jws, t.background);
        try jws.objectField("foreground");
        try writeHex(&jws, t.foreground);
        try jws.objectField("palette");
        try jws.beginArray();
        for (t.palette) |c| try writeHex(&jws, c);
        try jws.endArray();
        try jws.endObject();
    }
    try jws.endArray();
}

fn writeHex(jws: *std.json.Stringify, c: terminal_color.RGB) !void {
    var buf: [7]u8 = undefined;
    const hex = std.fmt.bufPrint(&buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ c.r, c.g, c.b }) catch unreachable;
    try jws.write(hex);
}

// Tests

const TestDir = struct {
    tmp: std.testing.TmpDir,
    root: []const u8,
    arena: ArenaAllocator,

    fn init() !TestDir {
        var arena: ArenaAllocator = .init(std.testing.allocator);
        errdefer arena.deinit();
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const len = try tmp.dir.realPath(global.io(), &buf);
        return .{
            .tmp = tmp,
            .root = try arena.allocator().dupe(u8, buf[0..len]),
            .arena = arena,
        };
    }

    fn deinit(self: *TestDir) void {
        self.tmp.cleanup();
        self.arena.deinit();
    }

    fn write(self: *TestDir, name: []const u8, data: []const u8) ![]const u8 {
        try self.tmp.dir.writeFile(global.io(), .{ .sub_path = name, .data = data });
        return try std.fs.path.join(self.arena.allocator(), &.{ self.root, name });
    }

    fn read(self: *TestDir, name: []const u8) ![]const u8 {
        return try self.tmp.dir.readFileAlloc(
            global.io(),
            name,
            self.arena.allocator(),
            .limited(64 * 1024),
        );
    }
};

fn testEditor(path: []const u8) !*Editor {
    return try Editor.create(std.testing.allocator, .{
        .path = path,
        .cli_args = false,
    });
}

test "set replaces in place" {
    const testing = std.testing;
    var dir: TestDir = try .init();
    defer dir.deinit();
    const path = try dir.write("config",
        \\# my config
        \\font-size = 13
        \\
        \\# end
        \\
    );

    const ed = try testEditor(path);
    defer ed.destroy();
    try testing.expectEqual(@as(f32, 13), ed.config.?.@"font-size");

    try ed.set("font-size", "15");
    try testing.expectEqualStrings(
        "# my config\nfont-size = 15\n\n# end\n",
        try dir.read("config"),
    );
    try testing.expectEqual(@as(f32, 15), ed.config.?.@"font-size");
}

test "set appends new keys" {
    const testing = std.testing;
    var dir: TestDir = try .init();
    defer dir.deinit();
    const path = try dir.write("config", "font-size = 13\n");

    const ed = try testEditor(path);
    defer ed.destroy();
    try ed.set("cursor-style", "bar");
    try ed.set("maximize", "true");
    try testing.expectEqualStrings(
        "font-size = 13\n\n" ++ edit_file.marker ++ "\ncursor-style = bar\nmaximize = true\n",
        try dir.read("config"),
    );
}

test "set rejects invalid values" {
    const testing = std.testing;
    var dir: TestDir = try .init();
    defer dir.deinit();
    const path = try dir.write("config", "font-size = 13\n");

    const ed = try testEditor(path);
    defer ed.destroy();
    try testing.expectError(error.InvalidValue, ed.set("cursor-style", "triangle"));
    try testing.expect(ed.lastMessage().len > 0);
    try testing.expectError(error.InvalidValue, ed.set("font-size", "1\nkeybind = a=quit"));
    try testing.expectError(error.UnknownKey, ed.set("not-a-key", "1"));
    try testing.expectEqualStrings("font-size = 13\n", try dir.read("config"));
}

test "set edits included files" {
    const testing = std.testing;
    var dir: TestDir = try .init();
    defer dir.deinit();
    _ = try dir.write("inc", "font-size = 12\n");
    const path = try dir.write("config", "font-size = 10\nconfig-file = inc\n");

    const ed = try testEditor(path);
    defer ed.destroy();
    try testing.expectEqual(@as(f32, 12), ed.config.?.@"font-size");

    try ed.set("font-size", "16");
    try testing.expectEqualStrings("font-size = 16\n", try dir.read("inc"));
    try testing.expectEqualStrings("font-size = 10\nconfig-file = inc\n", try dir.read("config"));
    try testing.expectEqual(@as(f32, 16), ed.config.?.@"font-size");
}

test "reset removes every entry" {
    const testing = std.testing;
    var dir: TestDir = try .init();
    defer dir.deinit();
    _ = try dir.write("inc", "font-size = 12\n# keep\n");
    const path = try dir.write("config", "font-size = 10\nconfig-file = inc\nfont-size = 11\n");

    const ed = try testEditor(path);
    defer ed.destroy();
    try ed.reset("font-size");
    try testing.expectEqualStrings("# keep\n", try dir.read("inc"));
    try testing.expectEqualStrings("config-file = inc\n", try dir.read("config"));

    var defaults = try Config.default(testing.allocator);
    defer defaults.deinit();
    try testing.expectEqual(defaults.@"font-size", ed.config.?.@"font-size");
}

test "repeatable keys" {
    const testing = std.testing;
    var dir: TestDir = try .init();
    defer dir.deinit();
    const path = try dir.write("config",
        \\font-family = A
        \\font-size = 10
        \\font-family = B
        \\
    );

    const ed = try testEditor(path);
    defer ed.destroy();

    try ed.setList("font-family", &.{ "B", "A", "C" });
    try testing.expectEqualStrings(
        "font-family = B\nfont-family = A\nfont-family = C\nfont-size = 10\n",
        try dir.read("config"),
    );

    try ed.add("keybind", "ctrl+a=new_window");
    try ed.add("keybind", "ctrl+b=new_tab");
    try testing.expectEqualStrings(
        "font-family = B\nfont-family = A\nfont-family = C\nfont-size = 10\n\n" ++
            edit_file.marker ++ "\nkeybind = ctrl+a=new_window\nkeybind = ctrl+b=new_tab\n",
        try dir.read("config"),
    );

    const line = ed.lastFileEntry("keybind").?.line;
    const p = try testing.allocator.dupe(u8, ed.lastFileEntry("keybind").?.path);
    defer testing.allocator.free(p);
    try ed.replaceEntry("keybind", p, line, "ctrl+c=new_tab");
    try ed.removeEntry("keybind", p, line - 1);
    try testing.expectEqualStrings(
        "font-family = B\nfont-family = A\nfont-family = C\nfont-size = 10\n\n" ++
            edit_file.marker ++ "\nkeybind = ctrl+c=new_tab\n",
        try dir.read("config"),
    );

    // Stale line numbers are detected.
    try testing.expectError(error.FileChanged, ed.removeEntry("keybind", p, 1));
}

test "setList replaces entries in every file" {
    const testing = std.testing;
    var dir: TestDir = try .init();
    defer dir.deinit();
    _ = try dir.write("inc", "font-family = B\n# keep\n");
    const path = try dir.write("config", "font-family = A\nconfig-file = inc\n");

    const ed = try testEditor(path);
    defer ed.destroy();

    const Check = struct {
        fn families(e: *Editor, expected: []const []const u8) !void {
            const entries = try e.fileEntries(testing.allocator, "font-family");
            defer testing.allocator.free(entries);
            try testing.expectEqual(expected.len, entries.len);
            for (expected, entries) |want, entry| try testing.expectEqualStrings(want, entry.value.?);
        }
    };
    try Check.families(ed, &.{ "A", "B" });

    // Reordering moves the included entry next to the first one instead
    // of leaving a duplicate behind in the included file.
    try ed.setList("font-family", &.{ "B", "A" });
    try testing.expectEqualStrings("font-family = B\nfont-family = A\nconfig-file = inc\n", try dir.read("config"));
    try testing.expectEqualStrings("# keep\n", try dir.read("inc"));
    try Check.families(ed, &.{ "B", "A" });

    // Removing a value removes it wherever it was.
    _ = try dir.write("inc", "font-family = C\n");
    try ed.reload();
    try Check.families(ed, &.{ "B", "A", "C" });
    try ed.setList("font-family", &.{ "B", "A" });
    try testing.expectEqualStrings("", try dir.read("inc"));
    try Check.families(ed, &.{ "B", "A" });

    // A key set only in an included file is written there.
    _ = try dir.write("config", "config-file = inc\n");
    _ = try dir.write("inc", "font-family = C\n");
    try ed.reload();
    try ed.setList("font-family", &.{ "D", "C" });
    try testing.expectEqualStrings("config-file = inc\n", try dir.read("config"));
    try testing.expectEqualStrings("font-family = D\nfont-family = C\n", try dir.read("inc"));
}

test "preview does not write" {
    const testing = std.testing;
    var dir: TestDir = try .init();
    defer dir.deinit();
    const path = try dir.write("config", "font-size = 13\n");

    const ed = try testEditor(path);
    defer ed.destroy();
    const cfg = try ed.preview("font-size", "20");
    defer {
        cfg.deinit();
        testing.allocator.destroy(cfg);
    }

    try testing.expectEqual(@as(f32, 20), cfg.@"font-size");
    try testing.expectEqualStrings("font-size = 13\n", try dir.read("config"));
}

test "snapshot json" {
    const testing = std.testing;
    var dir: TestDir = try .init();
    defer dir.deinit();
    const path = try dir.write("config", "font-size = 13\nnot-a-key = 1\n");

    const ed = try testEditor(path);
    defer ed.destroy();

    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try ed.writeSnapshotJson(&buf.writer);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, buf.written(), .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expectEqualStrings(path, root.get("primary_path").?.string);
    try testing.expectEqual(@as(usize, 1), root.get("diagnostics").?.array.items.len);
    const fs = root.get("values").?.object.get("font-size").?.array.items[0].string;
    try testing.expectEqualStrings("13", fs);
    const entry = root.get("entries").?.object.get("font-size").?.array.items[0].object;
    try testing.expectEqual(@as(i64, 1), entry.get("line").?.integer);
}
