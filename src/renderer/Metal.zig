//! Graphics API wrapper for Metal.
pub const Metal = @This();

const std = @import("std");
const global = @import("../global.zig");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const objc = @import("objc");
const macos = @import("macos");
const graphics = macos.graphics;
const apprt = @import("../apprt.zig");
const font = @import("../font/main.zig");
const configpkg = @import("../config.zig");
const rendererpkg = @import("../renderer.zig");
const Renderer = rendererpkg.GenericRenderer(Metal);
const shadertoy = @import("shadertoy.zig");

const mtl = @import("metal/api.zig");
const Atlas = @import("metal/Atlas.zig");
const AtlasCache = @import("metal/AtlasCache.zig");
const IOSurfaceLayer = @import("metal/IOSurfaceLayer.zig");
pub const Device = @import("metal/Device.zig");

pub const GraphicsAPI = Metal;
pub const Target = @import("metal/Target.zig");
pub const Frame = @import("metal/Frame.zig");
pub const RenderPass = @import("metal/RenderPass.zig");
pub const Pipeline = @import("metal/Pipeline.zig");
const bufferpkg = @import("metal/buffer.zig");
pub const Buffer = bufferpkg.Buffer;
pub const Sampler = @import("metal/Sampler.zig");
pub const Texture = @import("metal/Texture.zig");
pub const shaders = @import("metal/shaders.zig");

pub const custom_shader_target: shadertoy.Target = .msl;
// The fragCoord for Metal shaders is +Y = down.
pub const custom_shader_y_is_down = true;

/// Triple buffering.
pub const swap_chain_count = 3;

const log = std.log.scoped(.metal);

layer: IOSurfaceLayer,

/// The shared render device.
device: *const Device,

/// MTLCommandQueue
queue: objc.Object,

atlas: ?*AtlasCache.Entry = null,

/// Alpha blending mode
blending: configpkg.Config.AlphaBlending,

/// We start an AutoreleasePool before `drawFrame` and end it afterwards.
autorelease_pool: ?*objc.AutoreleasePool = null,

pub fn init(
    alloc: Allocator,
    device: *const Device,
    opts: rendererpkg.Options,
) !Metal {
    comptime switch (builtin.target.os.tag) {
        .macos, .ios => {},
        else => @compileError("unsupported platform for Metal"),
    };

    _ = alloc;

    // Shared atlas updates and readers must use one ordered queue.
    const queue = device.queue.retain();
    errdefer queue.release();

    const ViewInfo = struct {
        view: objc.Object,
        scaleFactor: f64,
    };

    // Get the metadata about our underlying view that we'll be rendering to.
    const info: ViewInfo = switch (apprt.runtime) {
        apprt.embedded => .{
            .scaleFactor = @floatCast(opts.rt_surface.content_scale.x),
            .view = switch (opts.rt_surface.platform) {
                .macos => |v| v.nsview,
                .ios => |v| v.uiview,
            },
        },

        else => @compileError("unsupported apprt for metal"),
    };

    // Create an IOSurfaceLayer which we can assign to the view to make
    // it in to a "layer-hosting view", so that we can manually control
    // the layer contents.
    var layer = try IOSurfaceLayer.init();
    errdefer layer.release();

    // Add our layer to the view.
    //
    // On macOS we do this by making the view "layer-hosting"
    // by assigning it to the view's `layer` property BEFORE
    // setting `wantsLayer` to `true`.
    //
    // On iOS, views are always layer-backed, and `layer`
    // is readonly, so instead we add it as a sublayer.
    switch (comptime builtin.target.os.tag) {
        .macos => {
            info.view.setProperty("layer", layer.layer.value);
            info.view.setProperty("wantsLayer", true);
        },

        .ios => {
            const view_layer = objc.Object.fromId(info.view.getProperty(?*anyopaque, "layer"));
            view_layer.msgSend(void, objc.sel("addSublayer:"), .{layer.layer.value});
        },

        else => @compileError("unsupported target for Metal"),
    }

    // Ensure that if our layer is oversized it
    // does not overflow the bounds of the view.
    info.view.setProperty("clipsToBounds", true);

    // Ensure that our layer has a content scale set to
    // match the scale factor of the window. This avoids
    // magnification issues leading to blurry rendering.
    layer.layer.setProperty("contentsScale", info.scaleFactor);

    // This makes it so that our display callback will actually be called.
    layer.layer.setProperty("needsDisplayOnBoundsChange", true);

    return .{
        .layer = layer,
        .device = device,
        .queue = queue,
        .blending = opts.config.blending,
    };
}

pub fn deinit(self: *Metal) void {
    self.releaseAtlas();
    self.queue.release();

    // The MTLDevice is app-scoped and destroyed
    // by the render device, not by us.

    self.layer.release();
}

pub fn loopEnter(self: *Metal) void {
    const renderer: *align(1) Renderer = @fieldParentPtr("api", self);
    self.layer.setDisplayCallback(
        @ptrCast(&displayCallback),
        @ptrCast(renderer),
    );
}

fn displayCallback(renderer: *Renderer) align(8) void {
    renderer.drawFrame(true) catch |err| {
        log.warn("Error drawing frame in display callback, err={}", .{err});
    };
}

/// Actions taken before doing anything in `drawFrame`.
///
/// Right now we use this to start an AutoreleasePool.
pub fn drawFrameStart(self: *Metal) void {
    assert(self.autorelease_pool == null);
    self.autorelease_pool = .init();
}

/// Actions taken after `drawFrame` is done.
///
/// Right now we use this to end our AutoreleasePool.
pub fn drawFrameEnd(self: *Metal) void {
    assert(self.autorelease_pool != null);
    self.autorelease_pool.?.deinit();
    self.autorelease_pool = null;
}

pub fn initShaders(
    self: *const Metal,
    alloc: Allocator,
    custom_shaders: []const [:0]const u8,
) !shaders.Shaders {
    return try shaders.Shaders.init(
        alloc,
        self.device.device,
        custom_shaders,
        // Using an `*_srgb` pixel format makes Metal gamma encode
        // the pixels written to it *after* blending, which means
        // we get linear alpha blending rather than gamma-incorrect
        // blending.
        if (self.blending.isLinear())
            mtl.MTLPixelFormat.bgra8unorm_srgb
        else
            mtl.MTLPixelFormat.bgra8unorm,
    );
}

/// Get the current size of the runtime surface.
pub fn surfaceSize(self: *const Metal) !struct { width: u32, height: u32 } {
    const bounds = self.layer.layer.getProperty(graphics.Rect, "bounds");
    const scale = self.layer.layer.getProperty(f64, "contentsScale");

    // We need to clamp our runtime surface size to the maximum
    // possible texture size since we can't create a screen buffer (texture)
    // larger than that.
    return .{
        .width = @min(
            @as(u32, @intFromFloat(bounds.size.width * scale)),
            self.device.max_texture_size,
        ),
        .height = @min(
            @as(u32, @intFromFloat(bounds.size.height * scale)),
            self.device.max_texture_size,
        ),
    };
}

/// Initialize a new render target which can be presented by this API.
pub fn initTarget(self: *const Metal, width: usize, height: usize) !Target {
    return Target.init(.{
        .device = self.device.device,
        // Using an `*_srgb` pixel format makes Metal gamma encode the pixels
        // written to it *after* blending, which means we get linear alpha
        // blending rather than gamma-incorrect blending.
        .pixel_format = if (self.blending.isLinear())
            .bgra8unorm_srgb
        else
            .bgra8unorm,
        .storage_mode = self.device.default_storage_mode,
        .width = width,
        .height = height,
    });
}

/// Present the provided target.
pub inline fn present(self: *Metal, target: Target, sync: bool) !void {
    if (sync) {
        self.layer.setSurfaceSync(target.surface);
    } else {
        try self.layer.setSurface(target.surface);
    }
}

/// Returns the options to use when constructing buffers.
pub inline fn bufferOptions(self: Metal) bufferpkg.Options {
    return .{
        .device = self.device.device,
        .resource_options = .{
            // Indicate that the CPU writes to this resource but never reads it.
            .cpu_cache_mode = .write_combined,
            .storage_mode = self.device.default_storage_mode,
        },
    };
}

pub const instanceBufferOptions = bufferOptions;
pub const uniformBufferOptions = bufferOptions;
pub const fgBufferOptions = bufferOptions;
pub const bgBufferOptions = bufferOptions;
pub const imageBufferOptions = bufferOptions;
pub const bgImageBufferOptions = bufferOptions;

/// Returns the options to use when constructing textures.
pub inline fn textureOptions(self: Metal) Texture.Options {
    return .{
        .device = self.device.device,
        // Using an `*_srgb` pixel format makes Metal gamma encode the pixels
        // written to it *after* blending, which means we get linear alpha
        // blending rather than gamma-incorrect blending.
        .pixel_format = if (self.blending.isLinear())
            .bgra8unorm_srgb
        else
            .bgra8unorm,
        .resource_options = .{
            // Indicate that the CPU writes to this resource but never reads it.
            .cpu_cache_mode = .write_combined,
            .storage_mode = self.device.default_storage_mode,
        },
        .usage = .{
            // textureOptions is currently only used for custom shaders,
            // which require both the shader read (for when multiple shaders
            // are chained) and render target (for the final output) usage.
            // Disabling either of these will lead to metal validation
            // errors in Xcode.
            .shader_read = true,
            .render_target = true,
        },
    };
}

pub inline fn samplerOptions(self: Metal) Sampler.Options {
    return .{
        .device = self.device.device,

        // These parameters match Shadertoy behaviors.
        .min_filter = .linear,
        .mag_filter = .linear,
        .s_address_mode = .clamp_to_edge,
        .t_address_mode = .clamp_to_edge,
    };
}

/// Pixel format for image texture options.
pub const ImageTextureFormat = enum {
    /// 1 byte per pixel grayscale.
    gray,
    /// 4 bytes per pixel RGBA.
    rgba,
    /// 4 bytes per pixel BGRA.
    bgra,

    fn toPixelFormat(
        self: ImageTextureFormat,
        srgb: bool,
    ) mtl.MTLPixelFormat {
        return switch (self) {
            .gray => if (srgb) .r8unorm_srgb else .r8unorm,
            .rgba => if (srgb) .rgba8unorm_srgb else .rgba8unorm,
            .bgra => if (srgb) .bgra8unorm_srgb else .bgra8unorm,
        };
    }
};

/// Returns the options to use when constructing textures for images.
pub inline fn imageTextureOptions(
    self: Metal,
    format: ImageTextureFormat,
    srgb: bool,
) Texture.Options {
    return .{
        .device = self.device.device,
        .pixel_format = format.toPixelFormat(srgb),
        .resource_options = .{
            // Indicate that the CPU writes to this resource but never reads it.
            .cpu_cache_mode = .write_combined,
            .storage_mode = self.device.default_storage_mode,
        },
        .usage = .{
            // We only need to read from this texture from a shader.
            .shader_read = true,
        },
    };
}

/// One atlas pair shared by all surfaces using this font grid.
pub fn syncAtlas(self: *Metal, frame: *Frame, grid: *font.SharedGrid) ![2]Texture {
    const entry = self.atlas orelse entry: {
        self.atlas = try self.device.atlases.acquire(grid);
        break :entry self.atlas.?;
    };
    assert(entry.grid == grid);
    entry.mutex.lockUncancelable(global.io());
    errdefer entry.mutex.unlock(global.io());
    const textures = try entry.atlas.sync(self.device.device, grid, frame.buffer);
    // Keep the entry locked until this buffer is committed. Merely locking
    // CPU uploads would let another surface submit a dependent draw first.
    frame.atlas = entry;
    return textures;
}

pub fn releaseAtlas(self: *Metal) void {
    if (self.atlas) |entry| self.device.atlases.release(entry);
    self.atlas = null;
}

/// Begin a frame.
pub inline fn beginFrame(
    self: *const Metal,
    /// Once the frame has been completed, the `frameCompleted` method
    /// on the renderer is called with the health status of the frame.
    renderer: *Renderer,
    /// The target is presented via the provided renderer's API when completed.
    target: *Target,
) !Frame {
    return try Frame.begin(.{ .queue = self.queue }, renderer, target);
}

test {
    _ = Atlas;
    _ = AtlasCache;
}

test "Metal discarded frame is not presented and releases its atlas lease" {
    const testing = std.testing;
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const device = objc.Object.fromId(mtl.MTLCreateSystemDefaultDevice() orelse return error.SkipZigTest);
    defer device.release();
    const queue = device.msgSend(objc.Object, objc.sel("newCommandQueue"), .{});
    defer queue.release();

    // The first allocation creates the cache. The second is the atlas
    // lease, which fails the way it would under memory pressure.
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    const cache = try AtlasCache.init(failing.allocator());
    defer cache.deinit();
    const device_ctx: Device = .{
        .device = device,
        .queue = queue,
        .atlases = cache,
        .default_storage_mode = .shared,
        .max_texture_size = 16384,
    };

    // Only the state touched by begin, syncAtlas, discard, and a
    // synchronous complete is valid.
    var r: Renderer = undefined;
    r.api.device = &device_ctx;
    r.api.queue = queue;
    r.api.atlas = null;
    r.api.layer = try IOSurfaceLayer.init();
    defer r.api.layer.release();
    defer r.api.releaseAtlas();
    r.health = .init(.healthy);
    r.swap_chain = .{ .frames = undefined };

    var target = try Target.init(.{
        .device = device,
        .width = 8,
        .height = 8,
        .pixel_format = .bgra8unorm,
        .storage_mode = .shared,
    });
    defer target.deinit();

    var grid: font.SharedGrid = .{
        .atlas_grayscale = try font.Atlas.init(testing.allocator, 8, .grayscale),
        .atlas_color = try font.Atlas.init(testing.allocator, 8, .bgra),
        .lock = .init,
        .resolver = undefined,
        .metrics = undefined,
    };
    defer grid.atlas_grayscale.deinit(testing.allocator);
    defer grid.atlas_color.deinit(testing.allocator);

    const Draw = struct {
        /// Mirrors `drawFrameLocked`: a frame that fails after `begin`
        /// is discarded, never completed.
        fn run(renderer: *Renderer, t: *Target, g: *font.SharedGrid) !void {
            var frame = try renderer.api.beginFrame(renderer, t);
            errdefer frame.discard();
            _ = try renderer.api.syncAtlas(&frame, g);
            frame.complete(true);
        }

        fn contents(renderer: *Renderer) ?*anyopaque {
            return renderer.api.layer.layer.getProperty(?*anyopaque, "contents");
        }
    };

    // The atlas lease fails to allocate. Nothing was drawn, so the
    // layer must keep its old contents.
    try testing.expectEqual(@as(?*anyopaque, null), Draw.contents(&r));
    try testing.expectError(error.OutOfMemory, Draw.run(&r, &target, &grid));
    try testing.expectEqual(@as(?*anyopaque, null), Draw.contents(&r));

    // The failing allocator rejects every allocation from the fail
    // index onward. Memory pressure is over, so later leases allocate
    // normally.
    cache.alloc = testing.allocator;

    // A frame discarded after a successful sync must not present, and
    // must release the shared atlas lease for other surfaces.
    {
        var frame = try r.api.beginFrame(&r, &target);
        _ = try r.api.syncAtlas(&frame, &grid);
        frame.discard();
    }
    try testing.expectEqual(@as(?*anyopaque, null), Draw.contents(&r));
    try testing.expect(r.api.atlas.?.mutex.tryLock());
    r.api.atlas.?.mutex.unlock(global.io());

    // The atlas uploads in the dropped buffer never ran, so the next
    // sync must upload both atlases in full.
    try testing.expectEqual(@as(usize, 0), r.api.atlas.?.atlas.grayscale.modified);
    try testing.expectEqual(@as(usize, 0), r.api.atlas.?.atlas.color.modified);

    // The next frame completes and presents normally.
    try Draw.run(&r, &target, &grid);
    try testing.expect(Draw.contents(&r) != null);
}
