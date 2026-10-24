//! GPU font atlases updated by ordered blits, rather than CPU writes into
//! textures which may still be sampled by an earlier frame.
const Atlas = @This();

const std = @import("std");
const objc = @import("objc");
const font = @import("../../font/main.zig");
const global = @import("../../global.zig");
const mtl = @import("api.zig");
const Texture = @import("Texture.zig");
const log = std.log.scoped(.metal_atlas);

grayscale: Plane = .{},
color: Plane = .{},

const Plane = struct {
    texture: ?Texture = null,
    modified: usize = 0,

    fn prepare(self: *Plane, device: objc.Object, source: *const font.Atlas) !?Upload {
        if (self.texture == null or self.texture.?.width != source.size) {
            const texture = try Texture.init(.{
                .device = device,
                .pixel_format = switch (source.format) {
                    .grayscale => .r8unorm,
                    .bgra => .bgra8unorm_srgb,
                    else => unreachable,
                },
                .resource_options = .{ .storage_mode = .private },
                .usage = .{ .shader_read = true },
            }, source.size, source.size, null);
            if (self.texture) |old| old.deinit();
            self.texture = texture;
            self.modified = 0;
            log.debug("allocate format={} size={} bytes={}", .{
                source.format, source.size, source.data.len,
            });
        }

        const region = source.modifiedRegion(self.modified) orelse return null;
        return .{
            .plane = self,
            .source = source,
            .region = region,
            .stride = std.mem.alignForward(usize, @as(usize, region.width) * source.format.depth(), 256),
            .version = source.modified.load(.monotonic),
        };
    }
};

const Upload = struct {
    plane: *Plane,
    source: *const font.Atlas,
    region: font.Atlas.Region,
    stride: usize,
    version: usize,

    fn len(self: Upload) usize {
        return self.stride * self.region.height;
    }
};

pub fn deinit(self: *Atlas) void {
    if (self.grayscale.texture) |texture| texture.deinit();
    if (self.color.texture) |texture| texture.deinit();
    self.* = .{};
}

/// Forget what the GPU textures hold, so the next `sync` uploads both
/// atlases in full. `sync` records an upload as done once it is encoded,
/// so a caller that drops the command buffer instead of committing it
/// must call this before anyone else syncs.
pub fn invalidate(self: *Atlas) void {
    self.grayscale.modified = 0;
    self.color.modified = 0;
}

/// The caller serializes encoding through command-buffer submission on one
/// queue. Metal retains both staging and textures until their GPU use ends.
pub fn sync(
    self: *Atlas,
    device: objc.Object,
    grid: *font.SharedGrid,
    command_buffer: objc.Object,
) ![2]Texture {
    grid.lock.lockSharedUncancelable(global.io());
    defer grid.lock.unlockShared(global.io());

    const uploads = [_]?Upload{
        try self.grayscale.prepare(device, &grid.atlas_grayscale),
        try self.color.prepare(device, &grid.atlas_color),
    };
    var total: usize = 0;
    for (uploads) |maybe| if (maybe) |upload| {
        total += upload.len();
    };
    if (total > 0) {
        // A single immutable allocation for the entire batch, including both
        // atlas formats. No per-glyph allocations or CPU/GPU waits.
        const staging = objc.Object.fromId(device.msgSend(
            ?*anyopaque,
            objc.sel("newBufferWithLength:options:"),
            .{ @as(c_ulong, total), @as(mtl.MTLResourceOptions, .{ .storage_mode = .shared }) },
        ) orelse return error.MetalFailed);
        defer staging.release();
        const bytes = staging.msgSend(?[*]u8, objc.sel("contents"), .{}) orelse
            return error.MetalFailed;

        var offset: usize = 0;
        for (uploads) |maybe| if (maybe) |upload| {
            const depth: usize = upload.source.format.depth();
            const row_bytes = @as(usize, upload.region.width) * depth;
            for (0..upload.region.height) |y| {
                const src = ((upload.region.y + y) * upload.source.size + upload.region.x) * depth;
                @memcpy(bytes[offset + y * upload.stride ..][0..row_bytes], upload.source.data[src..][0..row_bytes]);
            }
            offset += upload.len();
        };

        const blit = objc.Object.fromId(command_buffer.msgSend(
            ?*anyopaque,
            objc.sel("blitCommandEncoder"),
            .{},
        ) orelse return error.MetalFailed);
        defer blit.msgSend(void, objc.sel("endEncoding"), .{});

        offset = 0;
        for (uploads) |maybe| if (maybe) |upload| {
            blit.msgSend(void, objc.sel("copyFromBuffer:sourceOffset:sourceBytesPerRow:sourceBytesPerImage:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:"), .{
                staging.value,
                @as(c_ulong, offset),
                @as(c_ulong, upload.stride),
                @as(c_ulong, upload.len()),
                mtl.MTLSize{ .width = upload.region.width, .height = upload.region.height, .depth = 1 },
                upload.plane.texture.?.texture.value,
                @as(c_ulong, 0),
                @as(c_ulong, 0),
                mtl.MTLOrigin{ .x = upload.region.x, .y = upload.region.y, .z = 0 },
            });
            upload.plane.modified = upload.version;
            offset += upload.len();
        };
        log.debug("upload batch bytes={}", .{total});
    }

    return .{ self.grayscale.texture.?, self.color.texture.? };
}

test "Metal atlas ordered uploads and resource lifetime" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const device = objc.Object.fromId(mtl.MTLCreateSystemDefaultDevice() orelse return error.SkipZigTest);
    defer device.release();
    const queue = device.msgSend(objc.Object, objc.sel("newCommandQueue"), .{});
    defer queue.release();

    // Only atlas storage and its lock participate in uploads; no font face
    // or metrics are needed for this pixel-level GPU test.
    var grid: font.SharedGrid = .{
        .atlas_grayscale = try font.Atlas.init(alloc, 8, .grayscale),
        .atlas_color = try font.Atlas.init(alloc, 8, .bgra),
        .lock = .init,
        .resolver = undefined,
        .metrics = undefined,
    };
    defer grid.atlas_grayscale.deinit(alloc);
    defer grid.atlas_color.deinit(alloc);
    var atlas: Atlas = .{};
    defer atlas.deinit();

    var commands: [4]objc.Object = undefined;
    var readbacks: [4][2]objc.Object = undefined;
    var expected: [4][2][]u8 = undefined;
    var sizes: [4]u32 = undefined;
    var count: usize = 0;
    defer for (0..count) |i| {
        for (readbacks[i]) |buffer| buffer.release();
        for (expected[i]) |data| alloc.free(data);
    };
    for (&commands, 0..) |*command, i| {
        if (i == 2) {
            try grid.atlas_grayscale.grow(alloc, 16);
            try grid.atlas_color.grow(alloc, 16);
        } else if (i == 3) {
            grid.atlas_grayscale.clear();
            grid.atlas_color.clear();
        }
        // Non-aligned rows exercise source stride and staging alignment.
        const region: font.Atlas.Region = .{ .x = 2, .y = 1, .width = 3, .height = 2 };
        grid.atlas_grayscale.set(region, &.{ 1, 2, 3, 4, 5, @intCast(i + 10) });
        var color: [24]u8 = undefined;
        for (&color, 0..) |*byte, n| byte.* = @intCast(i * 30 + n);
        grid.atlas_color.set(region, &color);
        command.* = queue.msgSend(objc.Object, objc.sel("commandBuffer"), .{});
        const textures = try atlas.sync(device, &grid, command.*);
        // Unchanged frames reuse exactly the same GPU texture objects.
        const unchanged = try atlas.sync(device, &grid, command.*);
        for (textures, unchanged) |a, b| try testing.expectEqual(a.texture.value, b.texture.value);
        sizes[i] = grid.atlas_grayscale.size;
        const blit = command.msgSend(objc.Object, objc.sel("blitCommandEncoder"), .{});
        for (textures, 0..) |texture, j| {
            expected[i][j] = try alloc.dupe(u8, if (j == 0) grid.atlas_grayscale.data else grid.atlas_color.data);
            const bytes = 256 * texture.height;
            readbacks[i][j] = device.msgSend(objc.Object, objc.sel("newBufferWithLength:options:"), .{
                @as(c_ulong, bytes), @as(mtl.MTLResourceOptions, .{ .storage_mode = .shared }),
            });
            blit.msgSend(void, objc.sel("copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toBuffer:destinationOffset:destinationBytesPerRow:destinationBytesPerImage:"), .{
                texture.texture.value,
                @as(c_ulong, 0),
                @as(c_ulong, 0),
                mtl.MTLOrigin{ .x = 0, .y = 0, .z = 0 },
                mtl.MTLSize{ .width = texture.width, .height = texture.height, .depth = 1 },
                readbacks[i][j].value,
                @as(c_ulong, 0),
                @as(c_ulong, 256),
                @as(c_ulong, bytes),
            });
        }
        blit.msgSend(void, objc.sel("endEncoding"), .{});
        count += 1;
    }

    // Both old and current textures, as well as staging buffers, must survive
    // destroying the owner before any of these commands are submitted.
    atlas.deinit();
    for (commands) |command| command.msgSend(void, objc.sel("commit"), .{});
    for (commands, 0..) |command, i| {
        command.msgSend(void, objc.sel("waitUntilCompleted"), .{});
        try testing.expectEqual(mtl.MTLCommandBufferStatus.completed, command.getProperty(mtl.MTLCommandBufferStatus, "status"));
        for (readbacks[i], 0..) |buffer, j| {
            const bytes = buffer.msgSend([*]const u8, objc.sel("contents"), .{});
            const row_bytes = sizes[i] * @as(usize, if (j == 0) 1 else 4);
            for (0..sizes[i]) |y| try testing.expectEqualSlices(u8, expected[i][j][y * row_bytes ..][0..row_bytes], bytes[y * 256 ..][0..row_bytes]);
        }
    }
}

test "Metal atlas uploads again after a dropped command buffer" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const device = objc.Object.fromId(mtl.MTLCreateSystemDefaultDevice() orelse return error.SkipZigTest);
    defer device.release();
    const queue = device.msgSend(objc.Object, objc.sel("newCommandQueue"), .{});
    defer queue.release();

    var grid: font.SharedGrid = .{
        .atlas_grayscale = try font.Atlas.init(alloc, 8, .grayscale),
        .atlas_color = try font.Atlas.init(alloc, 8, .bgra),
        .lock = .init,
        .resolver = undefined,
        .metrics = undefined,
    };
    defer grid.atlas_grayscale.deinit(alloc);
    defer grid.atlas_color.deinit(alloc);
    var atlas: Atlas = .{};
    defer atlas.deinit();

    const region: font.Atlas.Region = .{ .x = 2, .y = 1, .width = 3, .height = 2 };
    grid.atlas_grayscale.set(region, &.{ 1, 2, 3, 4, 5, 6 });

    // The upload is encoded, but the buffer is dropped without a commit,
    // the way a discarded frame drops it.
    const dropped = queue.msgSend(objc.Object, objc.sel("commandBuffer"), .{});
    _ = try atlas.sync(device, &grid, dropped);
    atlas.invalidate();

    // The next sync must upload the data again rather than trust that
    // the dropped upload ran.
    const command = queue.msgSend(objc.Object, objc.sel("commandBuffer"), .{});
    const texture = (try atlas.sync(device, &grid, command))[0];
    const bytes = 256 * texture.height;
    const readback = device.msgSend(objc.Object, objc.sel("newBufferWithLength:options:"), .{
        @as(c_ulong, bytes), @as(mtl.MTLResourceOptions, .{ .storage_mode = .shared }),
    });
    defer readback.release();
    const blit = command.msgSend(objc.Object, objc.sel("blitCommandEncoder"), .{});
    blit.msgSend(void, objc.sel("copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toBuffer:destinationOffset:destinationBytesPerRow:destinationBytesPerImage:"), .{
        texture.texture.value,
        @as(c_ulong, 0),
        @as(c_ulong, 0),
        mtl.MTLOrigin{ .x = 0, .y = 0, .z = 0 },
        mtl.MTLSize{ .width = texture.width, .height = texture.height, .depth = 1 },
        readback.value,
        @as(c_ulong, 0),
        @as(c_ulong, 256),
        @as(c_ulong, bytes),
    });
    blit.msgSend(void, objc.sel("endEncoding"), .{});
    command.msgSend(void, objc.sel("commit"), .{});
    command.msgSend(void, objc.sel("waitUntilCompleted"), .{});
    try testing.expectEqual(mtl.MTLCommandBufferStatus.completed, command.getProperty(mtl.MTLCommandBufferStatus, "status"));

    const data = readback.msgSend([*]const u8, objc.sel("contents"), .{});
    const size = grid.atlas_grayscale.size;
    for (0..size) |y| try testing.expectEqualSlices(u8, grid.atlas_grayscale.data[y * size ..][0..size], data[y * 256 ..][0..size]);
}
