//! One GPU atlas pair per live SharedGrid on this Metal device. The grid
//! already identifies the font configuration, point size and display density.
const AtlasCache = @This();

const std = @import("std");
const assert = @import("../../quirks.zig").inlineAssert;
const global = @import("../../global.zig");
const font = @import("../../font/main.zig");
const Atlas = @import("Atlas.zig");
const log = std.log.scoped(.metal_atlas);

alloc: std.mem.Allocator,
mutex: std.Io.Mutex = .init,
entries: std.AutoHashMapUnmanaged(*font.SharedGrid, *Entry) = .{},

pub const Entry = struct {
    grid: *font.SharedGrid,
    refs: usize = 1,
    /// Held from atlas synchronization through command-buffer commit. All
    /// users submit on the device's common queue, so blits cannot overtake
    /// earlier draws and readers cannot overtake an upload they depend on.
    mutex: std.Io.Mutex = .init,
    atlas: Atlas = .{},
};

pub fn init(alloc: std.mem.Allocator) !*AtlasCache {
    const self = try alloc.create(AtlasCache);
    self.* = .{ .alloc = alloc };
    return self;
}

pub fn deinit(self: *AtlasCache) void {
    assert(self.entries.count() == 0);
    self.entries.deinit(self.alloc);
    self.alloc.destroy(self);
}

/// Each surface must release its entry before releasing its CPU grid. An
/// occluded surface releases its lease too; the last release drops the GPU
/// cache. Submitted Metal commands retain textures independently of the entry.
pub fn acquire(self: *AtlasCache, grid: *font.SharedGrid) !*Entry {
    self.mutex.lockUncancelable(global.io());
    defer self.mutex.unlock(global.io());
    if (self.entries.get(grid)) |entry| {
        entry.refs += 1;
        return entry;
    }

    const entry = try self.alloc.create(Entry);
    errdefer self.alloc.destroy(entry);
    entry.* = .{ .grid = grid };
    try self.entries.put(self.alloc, grid, entry);
    log.debug("cache acquire grid={*} entries={}", .{ grid, self.entries.count() });
    return entry;
}

pub fn release(self: *AtlasCache, entry: *Entry) void {
    self.mutex.lockUncancelable(global.io());
    defer self.mutex.unlock(global.io());
    assert(entry.refs > 0);
    entry.refs -= 1;
    if (entry.refs > 0) return;
    const removed = self.entries.remove(entry.grid);
    assert(removed);
    log.debug("cache release grid={*} entries={}", .{ entry.grid, self.entries.count() });
    entry.atlas.deinit();
    self.alloc.destroy(entry);
}

test "Metal atlas cache shares grids and releases the last reference" {
    const testing = std.testing;
    const cache = try AtlasCache.init(testing.allocator);
    defer cache.deinit();
    // Pointer identity is the key. Cache ownership does not inspect CPU grids.
    var a: font.SharedGrid = undefined;
    var b: font.SharedGrid = undefined;
    const first = try cache.acquire(&a);
    const second = try cache.acquire(&a);
    const different_size = try cache.acquire(&b);
    try testing.expect(first == second);
    try testing.expect(first != different_size);
    try testing.expectEqual(2, cache.entries.count());
    cache.release(first);
    try testing.expectEqual(1, second.refs);
    cache.release(different_size);
    try testing.expectEqual(1, cache.entries.count());
    cache.release(second);
    try testing.expectEqual(0, cache.entries.count());
    // The same address can safely be reused after the previous grid is gone.
    cache.release(try cache.acquire(&a));
}

test "Metal atlas cache concurrent surface leases" {
    const testing = std.testing;
    const cache = try AtlasCache.init(testing.allocator);
    defer cache.deinit();
    var grid: font.SharedGrid = undefined;
    const owner = try cache.acquire(&grid);
    defer cache.release(owner);
    const Worker = struct {
        fn run(shared: *AtlasCache, expected: *Entry) void {
            for (0..1000) |_| {
                const lease = shared.acquire(expected.grid) catch unreachable;
                assert(lease == expected);
                shared.release(lease);
            }
        }
    };
    var threads: [4]std.Thread = undefined;
    var started: usize = 0;
    defer for (threads[0..started]) |thread| thread.join();
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{ cache, owner });
        started += 1;
    }
}
