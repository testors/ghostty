//! Trace records every configuration entry that was parsed while
//! loading a configuration, in the order it was parsed, along with
//! where it came from (a file and line, or a CLI argument).
//!
//! This is used by the settings editor to know which file and line
//! defines the effective value of a key so that edits can be written
//! back to the right place. It is opt-in: a Config only records into
//! a trace if `Config._trace` is set before loading.
//!
//! The trace owns its own memory (separate from the Config arena)
//! because loading a theme replaces the Config and frees its arena.
const Trace = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const cli = @import("../cli.zig");

arena: ArenaAllocator,
entries: std.ArrayList(Entry) = .empty,

pub const Entry = struct {
    /// The configuration key, e.g. "font-size".
    key: []const u8,

    /// The raw value, e.g. "13". Null if the entry had no "=" at all
    /// (e.g. `--maximize` on the CLI or `maximize` alone on a line).
    value: ?[]const u8,

    /// Where the entry came from.
    location: Location,
};

pub const Location = union(enum) {
    /// The entry came from a file at the given 1-indexed line.
    file: struct {
        path: []const u8,
        line: usize,
    },

    /// The entry came from a CLI argument (1-indexed).
    cli: usize,
};

pub fn init(alloc: Allocator) Trace {
    return .{ .arena = .init(alloc) };
}

pub fn deinit(self: *Trace) void {
    self.arena.deinit();
    self.* = undefined;
}

/// Remove all entries.
pub fn clear(self: *Trace) void {
    self.entries = .empty;
    _ = self.arena.reset(.retain_capacity);
}

/// Record a raw argument (in the form `--key=value`) from the given
/// diagnostic location. Arguments that aren't configuration entries
/// (no "--" prefix) or that have no usable location are ignored.
pub fn record(
    self: *Trace,
    arg: []const u8,
    location: cli.Location,
) Allocator.Error!void {
    if (!std.mem.startsWith(u8, arg, "--")) return;
    const loc: Location = switch (location) {
        .none => return,
        .cli => |index| .{ .cli = index },
        .file => |file| .{ .file = .{
            .path = file.path,
            .line = file.line,
        } },
    };

    const alloc = self.arena.allocator();
    const body = arg[2..];
    const key, const value = if (std.mem.indexOfScalar(u8, body, '=')) |idx|
        .{ body[0..idx], body[idx + 1 ..] }
    else
        .{ body, null };

    if (key.len == 0) return;

    try self.entries.append(alloc, .{
        .key = try alloc.dupe(u8, key),
        .value = if (value) |v| try alloc.dupe(u8, v) else null,
        .location = switch (loc) {
            .cli => loc,
            .file => |f| .{ .file = .{
                .path = try alloc.dupe(u8, f.path),
                .line = f.line,
            } },
        },
    });
}

/// Remove every entry recorded before index `end`. This is used when
/// loading discards configuration (i.e. `config-default-files = false`).
pub fn discardBefore(self: *Trace, end: usize) void {
    if (end == 0) return;
    const len = self.entries.items.len;
    if (end >= len) {
        self.entries.clearRetainingCapacity();
        return;
    }

    std.mem.copyForwards(
        Entry,
        self.entries.items[0 .. len - end],
        self.entries.items[end..],
    );
    self.entries.shrinkRetainingCapacity(len - end);
}

/// Returns the last entry for the given key, if any. For scalar
/// configuration keys this is the entry that determines the
/// effective value.
pub fn last(self: *const Trace, key: []const u8) ?*const Entry {
    var i: usize = self.entries.items.len;
    while (i > 0) {
        i -= 1;
        const entry = &self.entries.items[i];
        if (std.mem.eql(u8, entry.key, key)) return entry;
    }

    return null;
}

test "record and last" {
    const testing = std.testing;
    var trace: Trace = .init(testing.allocator);
    defer trace.deinit();

    try trace.record("--font-size=13", .{ .file = .{ .path = "/a", .line = 2 } });
    try trace.record("--font-size=14", .{ .cli = 1 });
    try trace.record("--maximize", .{ .file = .{ .path = "/b", .line = 9 } });
    try trace.record("not-an-arg", .{ .cli = 2 });
    try trace.record("--font-size=99", .none);

    try testing.expectEqual(@as(usize, 3), trace.entries.items.len);
    const fs = trace.last("font-size").?;
    try testing.expectEqualStrings("14", fs.value.?);
    try testing.expectEqual(@as(usize, 1), fs.location.cli);

    const max = trace.last("maximize").?;
    try testing.expect(max.value == null);
    try testing.expectEqualStrings("/b", max.location.file.path);
    try testing.expectEqual(@as(usize, 9), max.location.file.line);

    try testing.expect(trace.last("nope") == null);
}

test "discardBefore" {
    const testing = std.testing;
    var trace: Trace = .init(testing.allocator);
    defer trace.deinit();

    try trace.record("--a=1", .{ .cli = 1 });
    try trace.record("--b=2", .{ .cli = 2 });
    try trace.record("--c=3", .{ .cli = 3 });
    trace.discardBefore(2);
    try testing.expectEqual(@as(usize, 1), trace.entries.items.len);
    try testing.expectEqualStrings("c", trace.entries.items[0].key);
}
