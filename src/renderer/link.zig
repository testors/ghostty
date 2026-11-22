const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const oni = @import("oniguruma");
const global = @import("../global.zig");
const inputpkg = @import("../input.zig");
const url = @import("../config/url.zig");
const link_text = @import("link_text.zig");
const terminal = @import("../terminal/main.zig");
const point = terminal.point;
const Screen = terminal.Screen;
const Terminal = terminal.Terminal;

const log = std.log.scoped(.renderer_link);

/// The link configuration needed for renderers.
pub const Link = struct {
    /// The regular expression to match the link against.
    regex: oni.Regex,

    /// The situations in which the link should be highlighted.
    highlight: inputpkg.Link.Highlight,

    /// See `inputpkg.Link.validate_paths`.
    validate_paths: bool,

    pub fn deinit(self: *Link) void {
        self.regex.deinit();
    }

    /// Returns true if this link's highlight condition matches the given mouse state.
    fn active(
        self: *const Link,
        mouse_viewport: ?point.Coordinate,
        mouse_mods: inputpkg.Mods,
    ) bool {
        return switch (self.highlight) {
            .always => true,
            .always_mods => |v| mouse_mods.equal(v),
            .hover => mouse_viewport != null,
            .hover_mods => |v| mouse_viewport != null and mouse_mods.equal(v),
        };
    }
};

/// A set of links. This provides a higher level API for renderers
/// to match against a viewport and determine if cells are part of
/// a link.
pub const Set = struct {
    links: []Link,

    /// Returns the slice of links from the configuration.
    pub fn fromConfig(
        alloc: Allocator,
        config: []const inputpkg.Link,
    ) !Set {
        var links: std.ArrayList(Link) = .empty;
        defer links.deinit(alloc);

        for (config) |link| {
            var regex = try link.oniRegex();
            errdefer regex.deinit();
            try links.append(alloc, .{
                .regex = regex,
                .highlight = link.highlight,
                .validate_paths = link.validate_paths,
            });
        }

        return .{ .links = try links.toOwnedSlice(alloc) };
    }

    pub fn deinit(self: *Set, alloc: Allocator) void {
        for (self.links) |*link| link.deinit();
        alloc.free(self.links);
    }

    /// Fills matches with the matches from regex link matches. `paths`
    /// is used to check the matches of links with `validate_paths`.
    pub fn renderCellMap(
        self: *const Set,
        alloc: Allocator,
        result: *terminal.RenderState.CellSet,
        render_state: *const terminal.RenderState,
        mouse_viewport: ?point.Coordinate,
        mouse_mods: inputpkg.Mods,
        paths: url.PathContext,
    ) !void {
        // Fast path, not very likely since we have default links.
        if (self.links.len == 0) return;

        // Determine if any links are active before building the string and
        // byte-to-cell map. Those buffers scale with viewport size and this
        // function runs during frame updates, so avoid allocating them when
        // the current mouse/modifier state can't highlight any regex links.
        for (self.links) |*link| {
            if (link.active(mouse_viewport, mouse_mods)) break;
        } else return;

        const rows: ViewportRows = .init(render_state);
        var finder: link_text.Finder = try .init(alloc, &rows);
        defer finder.deinit(alloc);
        var found: std.ArrayList(link_text.Finder.Link) = .empty;
        defer found.deinit(alloc);

        for (self.links) |*link| {
            if (!link.active(mouse_viewport, mouse_mods)) continue;

            // Hover links only highlight the match under the mouse.
            const target: ?point.Coordinate = switch (link.highlight) {
                .always, .always_mods => null,
                .hover, .hover_mods => mouse_viewport orelse continue,
            };

            found.clearRetainingCapacity();
            try finder.find(
                alloc,
                global.io(),
                &link.regex,
                if (link.validate_paths) paths else null,
                target,
                &found,
            );

            // Record the matches, with the spacers of wide characters.
            for (found.items) |match| for (match.cells()) |pt| {
                try result.put(alloc, pt, {});
                const cells = rows.cells(pt.y);
                if (cells[pt.x].wide == .wide and pt.x + 1 < cells.len) {
                    try result.put(alloc, .{ .x = pt.x + 1, .y = pt.y }, {});
                }
            };
        }
    }
};

/// The viewport rows of a render state, as a source for
/// `link_text.Finder`.
const ViewportRows = struct {
    rows: []const terminal.page.Row,
    row_cells: []const std.MultiArrayList(terminal.RenderState.Cell),

    fn init(state: *const terminal.RenderState) ViewportRows {
        const row_slice = state.row_data.slice();
        const start = state.viewportStart();
        return .{
            .rows = row_slice.items(.raw)[start..][0..state.rows],
            .row_cells = row_slice.items(.cells)[start..][0..state.rows],
        };
    }

    pub fn len(self: *const ViewportRows) usize {
        return self.rows.len;
    }

    pub fn cells(self: *const ViewportRows, y: usize) []const terminal.Cell {
        return self.row_cells[y].slice().items(.raw);
    }

    pub fn wrap(self: *const ViewportRows, y: usize) bool {
        return self.rows[y].wrap;
    }

    pub fn graphemes(self: *const ViewportRows, y: usize, x: usize) []const u21 {
        return self.row_cells[y].slice().items(.grapheme)[x];
    }
};

test "renderCellMap" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t: terminal.Terminal = try .init(testing.io, alloc, .{
        .cols = 5,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    const str = "1ABCD2EFGH\r\n3IJKL";
    s.nextSlice(str);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Get a set
    var set = try Set.fromConfig(alloc, &.{
        .{
            .regex = "AB",
            .action = .{ .open = {} },
            .highlight = .{ .always = {} },
        },

        .{
            .regex = "EF",
            .action = .{ .open = {} },
            .highlight = .{ .always = {} },
        },
    });
    defer set.deinit(alloc);

    // Get our matches
    var result: terminal.RenderState.CellSet = .empty;
    defer result.deinit(alloc);
    try set.renderCellMap(
        alloc,
        &result,
        &state,
        null,
        .{},
        .{},
    );
    try testing.expect(!result.contains(.{ .x = 0, .y = 0 }));
    try testing.expect(result.contains(.{ .x = 1, .y = 0 }));
    try testing.expect(result.contains(.{ .x = 2, .y = 0 }));
    try testing.expect(!result.contains(.{ .x = 3, .y = 0 }));
    try testing.expect(result.contains(.{ .x = 1, .y = 1 }));
    try testing.expect(!result.contains(.{ .x = 1, .y = 2 }));
}

test "renderCellMap hover links" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t: terminal.Terminal = try .init(testing.io, alloc, .{
        .cols = 5,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    const str = "1ABCD2EFGH\r\n3IJKL";
    s.nextSlice(str);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Get a set
    var set = try Set.fromConfig(alloc, &.{
        .{
            .regex = "AB",
            .action = .{ .open = {} },
            .highlight = .{ .hover = {} },
        },

        .{
            .regex = "EF",
            .action = .{ .open = {} },
            .highlight = .{ .always = {} },
        },
    });
    defer set.deinit(alloc);

    // Not hovering over the first link
    {
        var result: terminal.RenderState.CellSet = .empty;
        defer result.deinit(alloc);
        try set.renderCellMap(
            alloc,
            &result,
            &state,
            null,
            .{},
            .{},
        );

        // Test our matches
        try testing.expect(!result.contains(.{ .x = 0, .y = 0 }));
        try testing.expect(!result.contains(.{ .x = 1, .y = 0 }));
        try testing.expect(!result.contains(.{ .x = 2, .y = 0 }));
        try testing.expect(!result.contains(.{ .x = 3, .y = 0 }));
        try testing.expect(result.contains(.{ .x = 1, .y = 1 }));
        try testing.expect(!result.contains(.{ .x = 1, .y = 2 }));
    }

    // Hovering over the first link
    {
        var result: terminal.RenderState.CellSet = .empty;
        defer result.deinit(alloc);
        try set.renderCellMap(
            alloc,
            &result,
            &state,
            .{ .x = 1, .y = 0 },
            .{},
            .{},
        );

        // Test our matches
        try testing.expect(!result.contains(.{ .x = 0, .y = 0 }));
        try testing.expect(result.contains(.{ .x = 1, .y = 0 }));
        try testing.expect(result.contains(.{ .x = 2, .y = 0 }));
        try testing.expect(!result.contains(.{ .x = 3, .y = 0 }));
        try testing.expect(result.contains(.{ .x = 1, .y = 1 }));
        try testing.expect(!result.contains(.{ .x = 1, .y = 2 }));
    }
}

test "renderCellMap inactive links don't allocate" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t: terminal.Terminal = try .init(io, alloc, .{
        .cols = 5,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    const str = "1ABCD2EFGH\r\n3IJKL";
    s.nextSlice(str);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    var set = try Set.fromConfig(alloc, &.{
        .{
            .regex = "AB",
            .action = .{ .open = {} },
            .highlight = .{ .hover = {} },
        },

        .{
            .regex = "EF",
            .action = .{ .open = {} },
            .highlight = .{ .always_mods = .{ .ctrl = true } },
        },

        .{
            .regex = "IJ",
            .action = .{ .open = {} },
            .highlight = .{ .hover_mods = .{ .shift = true } },
        },
    });
    defer set.deinit(alloc);

    var failing = std.testing.FailingAllocator.init(
        alloc,
        .{ .fail_index = 0 },
    );
    const failing_alloc = failing.allocator();

    var result: terminal.RenderState.CellSet = .empty;
    defer result.deinit(failing_alloc);
    try set.renderCellMap(
        failing_alloc,
        &result,
        &state,
        null,
        .{},
        .{},
    );

    try testing.expectEqual(@as(usize, 0), result.count());
}

test "renderCellMap mods no match" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t: terminal.Terminal = try .init(testing.io, alloc, .{
        .cols = 5,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    const str = "1ABCD2EFGH\r\n3IJKL";
    s.nextSlice(str);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Get a set
    var set = try Set.fromConfig(alloc, &.{
        .{
            .regex = "AB",
            .action = .{ .open = {} },
            .highlight = .{ .always = {} },
        },

        .{
            .regex = "EF",
            .action = .{ .open = {} },
            .highlight = .{ .always_mods = .{ .ctrl = true } },
        },
    });
    defer set.deinit(alloc);

    // Get our matches
    var result: terminal.RenderState.CellSet = .empty;
    defer result.deinit(alloc);
    try set.renderCellMap(
        alloc,
        &result,
        &state,
        null,
        .{},
        .{},
    );

    // Test our matches
    try testing.expect(!result.contains(.{ .x = 0, .y = 0 }));
    try testing.expect(result.contains(.{ .x = 1, .y = 0 }));
    try testing.expect(result.contains(.{ .x = 2, .y = 0 }));
    try testing.expect(!result.contains(.{ .x = 3, .y = 0 }));
    try testing.expect(!result.contains(.{ .x = 1, .y = 1 }));
    try testing.expect(!result.contains(.{ .x = 1, .y = 2 }));
}

test "renderCellMap trims paths to what exists" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "Repos");
    try tmp.dir.createDirPath(io, "blah/blah");
    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    var pwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const pwd = try std.mem.print(&pwd_buf, "{s}/Repos", .{root});

    var t: terminal.Terminal = try .init(io, alloc, .{
        .cols = 40,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    // "../blah/blah" is x=4 to x=15, "input/output" is x=4 to x=15.
    s.nextSlice("see ../blah/blah for details\r\nsee input/output");

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    var set = try Set.fromConfig(alloc, &.{.{
        .regex = url.regex,
        .action = .{ .open = {} },
        .highlight = .{ .hover = {} },
        .validate_paths = true,
    }});
    defer set.deinit(alloc);

    const paths: url.PathContext = .{ .pwd = pwd };

    // Hovering the path highlights only the part that exists.
    {
        var result: terminal.RenderState.CellSet = .empty;
        defer result.deinit(alloc);
        try set.renderCellMap(alloc, &result, &state, .{ .x = 5, .y = 0 }, .{}, paths);
        try testing.expect(!result.contains(.{ .x = 3, .y = 0 }));
        try testing.expect(result.contains(.{ .x = 4, .y = 0 }));
        try testing.expect(result.contains(.{ .x = 15, .y = 0 }));
        try testing.expect(!result.contains(.{ .x = 17, .y = 0 }));
    }

    // Hovering the words after it highlights nothing.
    {
        var result: terminal.RenderState.CellSet = .empty;
        defer result.deinit(alloc);
        try set.renderCellMap(alloc, &result, &state, .{ .x = 17, .y = 0 }, .{}, paths);
        try testing.expectEqual(@as(usize, 0), result.count());
    }

    // A bare path without a dot isn't a link unless it exists.
    {
        var result: terminal.RenderState.CellSet = .empty;
        defer result.deinit(alloc);
        try set.renderCellMap(alloc, &result, &state, .{ .x = 5, .y = 1 }, .{}, paths);
        try testing.expectEqual(@as(usize, 0), result.count());
    }
}

test "renderCellMap joins links that a TUI broke over rows" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t: terminal.Terminal = try .init(testing.io, alloc, .{
        .cols = 20,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    // The URL is x=2 to x=17 of the first row and x=2 to x=6 of the second.
    s.nextSlice("│ https://example. │\r\n│ com/x            │");

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    var set = try Set.fromConfig(alloc, &.{.{
        .regex = url.regex,
        .action = .{ .open = {} },
        .highlight = .{ .hover = {} },
        .validate_paths = true,
    }});
    defer set.deinit(alloc);

    // Hovering either part highlights both, but not the frame.
    for ([_]point.Coordinate{ .{ .x = 4, .y = 0 }, .{ .x = 3, .y = 1 } }) |hover| {
        var result: terminal.RenderState.CellSet = .empty;
        defer result.deinit(alloc);
        try set.renderCellMap(alloc, &result, &state, hover, .{}, .{});
        try testing.expect(!result.contains(.{ .x = 0, .y = 0 }));
        try testing.expect(result.contains(.{ .x = 2, .y = 0 }));
        try testing.expect(result.contains(.{ .x = 17, .y = 0 }));
        try testing.expect(!result.contains(.{ .x = 19, .y = 0 }));
        try testing.expect(!result.contains(.{ .x = 0, .y = 1 }));
        try testing.expect(result.contains(.{ .x = 2, .y = 1 }));
        try testing.expect(result.contains(.{ .x = 6, .y = 1 }));
        try testing.expect(!result.contains(.{ .x = 7, .y = 1 }));
    }
}
