//! A description of every configuration key that settings UIs can use
//! to build their controls: the kind of value, valid values, where
//! the key belongs, when changes take effect and its documentation.
//!
//! The schema is derived from the `Config` struct at comptime so new
//! configuration keys automatically show up in settings UIs.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Config = @import("Config.zig");
const help_strings = @import("help_strings");

/// The kind of value a key holds. UIs pick a control based on this.
pub const Kind = enum {
    bool,
    int,
    float,
    string,
    /// One of `values`.
    @"enum",
    /// A comma-separated list of `flags`, each optionally prefixed
    /// with `no-` to disable it.
    flags,
    color,
    path,
    font,
    theme,
    keybind,
    palette,
    duration,
};

/// The settings page a key belongs to.
pub const Category = enum {
    general,
    appearance,
    font,
    window,
    terminal,
    mouse,
    keybindings,
    quick_terminal,
    notifications,
    macos,
    linux,
};

/// The platforms a key applies to.
pub const Platform = enum {
    all,
    macos,
    linux,

    /// True if the key applies to the platform we're built for.
    pub fn current(self: Platform) bool {
        return switch (self) {
            .all => true,
            .macos => builtin.target.os.tag.isDarwin(),
            .linux => !builtin.target.os.tag.isDarwin(),
        };
    }
};

/// When a change to the key takes effect.
pub const Apply = enum {
    /// Applied to all open terminals when the configuration reloads.
    live,
    /// Only terminals created after the change use it.
    new_terminal,
    /// Only windows created after the change use it.
    new_window,
    /// Ghostty must be restarted.
    restart,
};

pub const Entry = struct {
    key: [:0]const u8,
    category: Category,
    kind: Kind,

    /// True if the key can be unset (an empty value means "default
    /// behavior" rather than a specific value).
    optional: bool,

    /// True if the key can be set multiple times and each entry adds
    /// a value (e.g. `keybind`, `font-family`).
    repeatable: bool,

    /// Valid values for enums. For other kinds, well known values a
    /// UI can suggest (e.g. `true`/`false` for `background-blur`).
    values: []const [:0]const u8,

    /// The flag names for `flags`.
    flags: []const [:0]const u8,

    platform: Platform,
    apply: Apply,

    /// The full documentation (Markdown-ish, from the source).
    doc: [:0]const u8,
};

/// All configuration keys in the order they're defined in Config.
pub const entries: []const Entry = entries: {
    @setEvalBranchQuota(1_000_000);
    const info = @typeInfo(Config).@"struct";
    var result: []const Entry = &.{};
    for (info.field_names, info.field_types) |name, T| {
        if (name[0] == '_') continue;
        const c = classify(name, T);
        result = result ++ &[_]Entry{.{
            .key = name,
            .category = categoryOf(name),
            .kind = c.kind,
            .optional = c.optional,
            .repeatable = c.repeatable,
            .values = c.values,
            .flags = c.flags,
            .platform = platformOf(name),
            .apply = applyOf(name),
            .doc = if (@hasDecl(help_strings.Config, name))
                @field(help_strings.Config, name)
            else
                "",
        }};
    }

    break :entries result;
};

/// Returns the schema entry for a key.
pub fn get(key: []const u8) ?*const Entry {
    for (entries) |*entry| {
        if (std.mem.eql(u8, entry.key, key)) return entry;
    }

    return null;
}

const Classified = struct {
    kind: Kind,
    optional: bool = false,
    repeatable: bool = false,
    values: []const [:0]const u8 = &.{},
    flags: []const [:0]const u8 = &.{},
};

fn classify(comptime name: []const u8, comptime T0: type) Classified {
    const optional = @typeInfo(T0) == .optional;
    const T = if (optional) @typeInfo(T0).optional.child else T0;

    // Keys that hold font family names get a font picker.
    if (std.mem.startsWith(u8, name, "font-family") or
        std.mem.eql(u8, name, "window-title-font-family"))
    {
        return .{
            .kind = .font,
            .optional = optional,
            .repeatable = T == Config.RepeatableString,
        };
    }

    if (T == Config.Color or
        T == Config.TerminalColor or
        T == Config.BoldColor)
    {
        return .{
            .kind = .color,
            .optional = optional,
            .values = unionVoidNames(T),
        };
    }

    if (T == Config.Path) return .{ .kind = .path, .optional = optional };
    if (T == Config.RepeatablePath) return .{ .kind = .path, .repeatable = true };
    if (T == Config.Theme) return .{ .kind = .theme, .optional = optional };
    if (T == Config.Keybinds) return .{ .kind = .keybind, .repeatable = true };
    if (T == Config.Palette) return .{ .kind = .palette, .repeatable = true };
    if (T == Config.Duration) return .{ .kind = .duration, .optional = optional };

    switch (@typeInfo(T)) {
        .bool => return .{ .kind = .bool, .optional = optional },
        .int => return .{ .kind = .int, .optional = optional },
        .float => return .{ .kind = .float, .optional = optional },
        .@"enum" => |e| return .{
            .kind = .@"enum",
            .optional = optional,
            .values = e.field_names,
        },

        .@"struct" => |s| {
            if (s.layout == .@"packed" and allBool(s.field_types)) {
                return .{
                    .kind = .flags,
                    .optional = optional,
                    .flags = s.field_names,
                };
            }
        },

        .@"union" => return .{
            .kind = .string,
            .optional = optional,
            .values = unionVoidNames(T),
            .repeatable = isRepeatable(T),
        },

        else => {},
    }

    return .{
        .kind = .string,
        .optional = optional,
        .repeatable = isRepeatable(T),
    };
}

fn allBool(comptime types: []const type) bool {
    for (types) |T| if (T != bool) return false;
    return true;
}

/// The names of the void fields of a tagged union. These are the
/// keyword values of union-typed configuration (e.g. `cell-foreground`
/// for terminal colors).
fn unionVoidNames(comptime T: type) []const [:0]const u8 {
    const info = switch (@typeInfo(T)) {
        .@"union" => |u| u,
        else => return &.{},
    };

    var result: []const [:0]const u8 = &.{};
    for (info.field_names, info.field_types) |name, FT| {
        if (FT == void) result = result ++ &[_][:0]const u8{name};
    }

    return result;
}

fn isRepeatable(comptime T: type) bool {
    const name = @typeName(T);
    if (std.mem.indexOf(u8, name, "Repeatable") != null) return true;
    if (std.mem.endsWith(u8, name, "RemapSet")) return true;
    return false;
}

fn categoryOf(comptime key: []const u8) Category {
    const exact = .{
        .{ "language", .general },
        .{ "command", .general },
        .{ "initial-command", .general },
        .{ "env", .general },
        .{ "input", .general },
        .{ "wait-after-command", .general },
        .{ "abnormal-command-exit-runtime", .general },
        .{ "working-directory", .general },
        .{ "window-save-state", .general },
        .{ "config-file", .general },
        .{ "config-default-files", .general },
        .{ "confirm-close-surface", .general },
        .{ "quit-after-last-window-closed", .general },
        .{ "quit-after-last-window-closed-delay", .general },
        .{ "initial-window", .general },
        .{ "undo-timeout", .general },
        .{ "auto-update", .general },
        .{ "auto-update-channel", .general },

        .{ "alpha-blending", .font },
        .{ "freetype-load-flags", .font },

        .{ "theme", .appearance },
        .{ "background", .appearance },
        .{ "foreground", .appearance },
        .{ "minimum-contrast", .appearance },
        .{ "bold-color", .appearance },
        .{ "faint-opacity", .appearance },
        .{ "split-divider-color", .appearance },
        .{ "selection-foreground", .appearance },
        .{ "selection-background", .appearance },

        .{ "selection-clear-on-typing", .mouse },
        .{ "selection-clear-on-copy", .mouse },
        .{ "selection-word-chars", .mouse },
        .{ "cursor-click-to-move", .mouse },
        .{ "focus-follows-mouse", .mouse },
        .{ "copy-on-select", .mouse },
        .{ "right-click-action", .mouse },
        .{ "middle-click-action", .mouse },
        .{ "click-repeat-interval", .mouse },
        .{ "clipboard-codepoint-map", .mouse },

        .{ "grapheme-width-method", .terminal },
        .{ "scroll-to-bottom", .terminal },
        .{ "title-report", .terminal },
        .{ "image-storage-limit", .terminal },
        .{ "osc-color-report-format", .terminal },
        .{ "term", .terminal },
        .{ "enquiry-response", .terminal },

        .{ "maximize", .window },
        .{ "fullscreen", .window },
        .{ "title", .window },
        .{ "drag-handle", .window },
        .{ "progress-style", .window },
        .{ "split-preserve-zoom", .window },
        .{ "tab-inherit-working-directory", .window },
        .{ "tab-title-format", .window },
        .{ "split-inherit-working-directory", .window },

        .{ "keybind", .keybindings },
        .{ "key-remap", .keybindings },
        .{ "command-palette-entry", .keybindings },

        .{ "app-notifications", .notifications },
        .{ "desktop-notifications", .notifications },

        .{ "class", .linux },
        .{ "x11-instance-name", .linux },
        .{ "async-backend", .linux },
    };

    inline for (exact) |pair| {
        if (std.mem.eql(u8, key, pair[0])) return pair[1];
    }

    const prefixes = .{
        .{ "font-", .font },
        .{ "adjust-", .font },
        .{ "background-", .appearance },
        .{ "palette", .appearance },
        .{ "cursor-", .appearance },
        .{ "unfocused-split-", .appearance },
        .{ "search-", .appearance },
        .{ "custom-shader", .appearance },
        .{ "mouse-", .mouse },
        .{ "clipboard-", .mouse },
        .{ "scrollback-", .terminal },
        .{ "scrollbar", .terminal },
        .{ "link", .terminal },
        .{ "shell-integration", .terminal },
        .{ "vt-", .terminal },
        .{ "window-", .window },
        .{ "resize-overlay", .window },
        .{ "quick-terminal-", .quick_terminal },
        .{ "gtk-quick-terminal-", .quick_terminal },
        .{ "notify-on-command-finish", .notifications },
        .{ "bell-", .notifications },
        .{ "macos-", .macos },
        .{ "gtk-", .linux },
        .{ "linux-", .linux },
    };

    inline for (prefixes) |pair| {
        if (std.mem.startsWith(u8, key, pair[0])) return pair[1];
    }

    return .general;
}

fn platformOf(comptime key: []const u8) Platform {
    const macos = [_][]const u8{
        "auto-update",
        "auto-update-channel",
        "window-step-resize",
        "quick-terminal-space-behavior",
    };
    const linux = [_][]const u8{
        "class",
        "x11-instance-name",
        "async-backend",
        "freetype-load-flags",
        "quick-terminal-keyboard-interactivity",
    };

    for (macos) |k| if (std.mem.eql(u8, key, k)) return .macos;
    for (linux) |k| if (std.mem.eql(u8, key, k)) return .linux;
    if (std.mem.startsWith(u8, key, "macos-")) return .macos;
    if (std.mem.startsWith(u8, key, "gtk-")) return .linux;
    if (std.mem.startsWith(u8, key, "linux-")) return .linux;
    return .all;
}

fn applyOf(comptime key: []const u8) Apply {
    // These come from the documentation of each key.
    const restart = [_][]const u8{
        "language",
        "async-backend",
        "auto-update-channel",
    };
    const restart_macos = [_][]const u8{
        "background-opacity",
        "quick-terminal-position",
    };
    const new_terminal = [_][]const u8{
        "command",
        "initial-command",
        "input",
        "env",
        "working-directory",
        "wait-after-command",
        "abnormal-command-exit-runtime",
        "font-codepoint-map",
        "grapheme-width-method",
        "scrollback-limit-bytes",
        "scrollback-limit-lines",
        "window-padding-x",
        "window-padding-y",
        "window-vsync",
        "shell-integration",
        "shell-integration-features",
        "term",
        "linux-cgroup",
        "linux-cgroup-memory-limit",
        "linux-cgroup-processes-limit",
        "linux-cgroup-hard-fail",
    };
    const new_window = [_][]const u8{
        "maximize",
        "fullscreen",
        "window-height",
        "window-width",
        "window-position-x",
        "window-position-y",
        "initial-window",
        "macos-window-buttons",
        "macos-titlebar-style",
    };

    for (restart) |k| if (std.mem.eql(u8, key, k)) return .restart;
    if (comptime builtin.target.os.tag.isDarwin()) {
        for (restart_macos) |k| if (std.mem.eql(u8, key, k)) return .restart;
    }
    for (new_terminal) |k| if (std.mem.eql(u8, key, k)) return .new_terminal;
    for (new_window) |k| if (std.mem.eql(u8, key, k)) return .new_window;
    return .live;
}

/// A human readable label for a key, e.g. "macos-titlebar-style"
/// becomes "Titlebar style". The prefix shared with the key's
/// category is dropped since UIs show the key on that category's page.
pub fn label(alloc: Allocator, entry: *const Entry) Allocator.Error![]const u8 {
    const overrides = std.StaticStringMap([]const u8).initComptime(.{
        .{ "macos-option-as-alt", "Option as Alt" },
        .{ "window-remote-indicator", "Remote session indicator" },
        .{ "macos-non-native-fullscreen", "Non-native fullscreen" },
        .{ "macos-applescript", "AppleScript" },
        .{ "macos-icon", "App icon" },
        .{ "macos-custom-icon", "Custom app icon" },
        .{ "macos-icon-frame", "App icon frame" },
        .{ "macos-icon-ghost-color", "App icon ghost color" },
        .{ "macos-icon-screen-color", "App icon screen color" },
        .{ "gtk-custom-css", "Custom CSS" },
        .{ "gtk-opengl-debug", "OpenGL debug" },
        .{ "osc-color-report-format", "OSC color report format" },
        .{ "vt-kam-allowed", "Allow keyboard action mode (KAM)" },
        .{ "vt-xt-checksum-report", "XTCHECKSUM report" },
        .{ "vt-xt-checksum-extension", "XTCHECKSUM extension" },
        .{ "term", "TERM" },
        .{ "env", "Environment variables" },
        .{ "x11-instance-name", "X11 instance name" },
        .{ "font-family", "Font family" },
        .{ "font-size", "Font size" },
        .{ "keybind", "Keybindings" },
        .{ "theme", "Theme" },
        .{ "palette", "Palette" },
        .{ "background", "Background color" },
        .{ "foreground", "Foreground color" },
        .{ "link-url", "Detect URLs" },
        .{ "link-osc8", "OSC 8 hyperlinks" },
        .{ "auto-update", "Automatic updates" },
        .{ "command", "Command" },
        .{ "config-file", "Additional config files" },
        .{ "window-padding-x", "Horizontal padding" },
        .{ "window-padding-y", "Vertical padding" },
        .{ "window-padding-balance", "Balance padding" },
        .{ "window-padding-color", "Padding color" },
    });
    if (overrides.get(entry.key)) |v| return try alloc.dupe(u8, v);

    const prefix: []const u8 = switch (entry.category) {
        .macos => "macos-",
        .quick_terminal => if (std.mem.startsWith(u8, entry.key, "gtk-"))
            "gtk-quick-terminal-"
        else
            "quick-terminal-",
        .linux => if (std.mem.startsWith(u8, entry.key, "gtk-")) "gtk-" else "",
        else => "",
    };

    var name: []const u8 = entry.key;
    if (prefix.len > 0 and std.mem.startsWith(u8, name, prefix) and name.len > prefix.len) {
        name = name[prefix.len..];
    }

    const result = try alloc.dupe(u8, name);
    for (result) |*ch| {
        if (ch.* == '-') ch.* = ' ';
    }
    if (result.len > 0) result[0] = std.ascii.toUpper(result[0]);
    return result;
}

/// The first paragraph of the documentation as a single line.
pub fn summary(alloc: Allocator, entry: *const Entry) Allocator.Error![]const u8 {
    const doc = entry.doc;
    const end = std.mem.indexOf(u8, doc, "\n\n") orelse doc.len;
    const para = doc[0..end];
    const result = try alloc.alloc(u8, para.len);
    var len: usize = 0;
    var prev_space = false;
    for (para) |ch| {
        const c = if (ch == '\n') ' ' else ch;
        if (c == ' ' and prev_space) continue;
        prev_space = c == ' ';
        result[len] = c;
        len += 1;
    }

    return result[0..len];
}

/// Write the whole schema as JSON. Only keys for the current platform
/// are included.
pub fn writeJson(alloc: Allocator, writer: *std.Io.Writer) !void {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // Default values come from a default configuration.
    var defaults = try Config.default(alloc);
    defer defaults.deinit();

    var jws: std.json.Stringify = .{ .writer = writer };
    try jws.beginArray();
    for (entries) |*entry| {
        if (!entry.platform.current()) continue;

        try jws.beginObject();
        try jws.objectField("key");
        try jws.write(entry.key);
        try jws.objectField("label");
        try jws.write(try label(arena_alloc, entry));
        try jws.objectField("category");
        try jws.write(@tagName(entry.category));
        try jws.objectField("kind");
        try jws.write(@tagName(entry.kind));
        try jws.objectField("optional");
        try jws.write(entry.optional);
        try jws.objectField("repeatable");
        try jws.write(entry.repeatable);
        try jws.objectField("values");
        try jws.write(entry.values);
        try jws.objectField("flags");
        try jws.write(entry.flags);
        try jws.objectField("platform");
        try jws.write(@tagName(entry.platform));
        try jws.objectField("apply");
        try jws.write(@tagName(entry.apply));
        try jws.objectField("default");
        try jws.write(try formatValues(arena_alloc, &defaults, entry.key));
        try jws.objectField("summary");
        try jws.write(try summary(arena_alloc, entry));
        try jws.objectField("doc");
        try jws.write(entry.doc);
        try jws.endObject();
    }
    try jws.endArray();
}

/// Write the keybinding actions as JSON for keybinding editors:
///
///   * `commands`: well known actions (with parameters) and a human
///     readable title, the same list as the command palette.
///   * `actions`: every action name and whether it takes a parameter.
pub fn writeKeybindActionsJson(writer: *std.Io.Writer) !void {
    const Binding = @import("../input/Binding.zig");
    const command = @import("../input/command.zig");

    var jws: std.json.Stringify = .{ .writer = writer };
    try jws.beginObject();

    try jws.objectField("commands");
    try jws.beginArray();
    for (command.defaultsC) |cmd| {
        try jws.beginObject();
        try jws.objectField("action");
        try jws.write(std.mem.span(cmd.action));
        try jws.objectField("title");
        try jws.write(std.mem.span(cmd.title));
        try jws.objectField("description");
        try jws.write(std.mem.span(cmd.description));
        try jws.endObject();
    }
    try jws.endArray();

    try jws.objectField("actions");
    try jws.beginArray();
    const info = @typeInfo(Binding.Action).@"union";
    inline for (info.field_names, info.field_types) |name, T| {
        if (comptime name[0] == '_') continue;
        try jws.beginObject();
        try jws.objectField("name");
        try jws.write(name);
        try jws.objectField("param");
        try jws.write(T != void);
        try jws.endObject();
    }
    try jws.endArray();

    try jws.endObject();
}

/// Format the value of a key in a configuration as the list of values
/// that would be written to a configuration file (one per line for
/// repeatable keys). An unset value results in a single empty string.
pub fn formatValues(
    alloc: Allocator,
    config: *const Config,
    key: []const u8,
) ![]const []const u8 {
    @setEvalBranchQuota(100_000);
    const formatter = @import("formatter.zig");
    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();

    const info = @typeInfo(Config).@"struct";
    inline for (info.field_names, info.field_types) |name, T| {
        if (comptime name[0] == '_') continue;
        if (std.mem.eql(u8, name, key)) {
            try formatter.formatEntry(T, name, @field(config, name), &buf.writer);
            break;
        }
    } else return &.{};

    var result: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, buf.written(), '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const prefix_len = key.len + " = ".len;
        const value = if (line.len >= prefix_len) line[prefix_len..] else "";
        try result.append(alloc, try alloc.dupe(u8, value));
    }

    return try result.toOwnedSlice(alloc);
}

test "every key has an entry" {
    const testing = std.testing;
    const Key = @import("key.zig").Key;
    try testing.expectEqual(
        @typeInfo(Key).@"enum".field_names.len,
        entries.len,
    );
}

test "classification" {
    const testing = std.testing;
    try testing.expectEqual(Kind.bool, get("maximize").?.kind);
    try testing.expectEqual(Kind.float, get("background-opacity").?.kind);
    try testing.expectEqual(Kind.@"enum", get("cursor-style").?.kind);
    try testing.expectEqual(Kind.theme, get("theme").?.kind);
    try testing.expectEqual(Kind.keybind, get("keybind").?.kind);
    try testing.expectEqual(Kind.color, get("background").?.kind);
    try testing.expectEqual(Kind.font, get("font-family").?.kind);
    try testing.expect(get("font-family").?.repeatable);
    try testing.expect(get("config-file").?.repeatable);
    try testing.expectEqual(Kind.flags, get("bell-features").?.kind);
    try testing.expect(get("cursor-style-blink").?.optional);
    try testing.expectEqual(Category.macos, get("macos-titlebar-style").?.category);
    try testing.expectEqual(Category.font, get("adjust-cell-height").?.category);
    try testing.expectEqual(Category.window, get("tab-title-format").?.category);
    try testing.expectEqual(Apply.new_window, get("macos-titlebar-style").?.apply);
    try testing.expectEqual(Platform.linux, get("gtk-wide-tabs").?.platform);
    try testing.expect(get("nope") == null);
}

test "label and summary" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try testing.expectEqualStrings(
        "Titlebar style",
        try label(alloc, get("macos-titlebar-style").?),
    );
    try testing.expectEqualStrings(
        "Background opacity",
        try label(alloc, get("background-opacity").?),
    );
    const s = try summary(alloc, get("background-opacity-cells").?);
    try testing.expect(std.mem.startsWith(u8, s, "Applies background opacity to cells"));
    try testing.expect(std.mem.indexOfScalar(u8, s, '\n') == null);
}

test "formatValues" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cfg = try Config.default(testing.allocator);
    defer cfg.deinit();
    cfg.@"font-size" = 15;

    const fs = try formatValues(alloc, &cfg, "font-size");
    try testing.expectEqual(@as(usize, 1), fs.len);
    try testing.expectEqualStrings("15", fs[0]);

    const kb = try formatValues(alloc, &cfg, "keybind");
    try testing.expect(kb.len > 10);
}

test "writeKeybindActionsJson" {
    const testing = std.testing;
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try writeKeybindActionsJson(&buf.writer);

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        buf.written(),
        .{},
    );
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("commands").?.array.items.len > 10);
    try testing.expect(parsed.value.object.get("actions").?.array.items.len > 10);
}

test "writeJson" {
    const testing = std.testing;
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try writeJson(testing.allocator, &buf.writer);

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        buf.written(),
        .{},
    );
    defer parsed.deinit();
    try testing.expect(parsed.value.array.items.len > 100);
}
