//! Finds the links in rows of the screen, including links a TUI broke
//! over rows.
//!
//! TUIs such as Claude Code, Codex and OpenCode lay out their own text.
//! A path or URL too long for the space it's shown in is broken over
//! rows with newlines, and the rows after the first start with the TUI's
//! indentation or frame:
//!
//!     ⏺ /Users/me/src/ghostty/src/renderer/l
//!       ink.zig is where links are drawn.
//!
//!     │ https://github.com/ghostty-org/ghostty/pull/12 │
//!     │ 345                                            │
//!
//! The terminal sees separate lines there, not a soft wrap, so the link
//! would end at the break. `Finder` joins such rows when the break looks
//! like one a TUI made inside a word: the upper row's text reaches the
//! right edge of the space it's in, and the lower row's text starts after
//! nothing but blanks and vertical lines. A link across the join must
//! then exist on disk, for a local path, or pass `fits`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const oni = @import("oniguruma");
const url = @import("../config/url.zig");
const terminal = @import("../terminal/main.zig");
const Cell = terminal.Cell;
const Coordinate = terminal.point.Coordinate;
const CellCountInt = terminal.size.CellCountInt;

/// The most joins a link can go across, which bounds the rows a click
/// looks at.
pub const max_joins = url.max_ends;

/// The most blank columns between the end of a row's text and the right
/// edge of the space it's in for the row to be joined to the next. TUIs
/// pad their text, so the edge can be a few columns past where a broken
/// word ends. Across a gap, only paths that exist on disk are joined,
/// unless `fits` can tell the gap is padding.
const max_gap = 8;

/// The text of rows of the screen, to find links in.
pub const Text = struct {
    string: std.ArrayList(u8) = .empty,

    /// The cell of each byte of `string`: its column and the index of
    /// its row. A newline's is the column after the end of its row.
    map: std.ArrayList(Coordinate) = .empty,

    /// Where rows are joined in `string`, in order.
    joins: std.ArrayList(Join) = .empty,

    pub fn deinit(self: *Text, alloc: Allocator) void {
        self.string.deinit(alloc);
        self.map.deinit(alloc);
        self.joins.deinit(alloc);
    }

    /// Builds the text of the rows of `source`, see `Finder.init`. If
    /// `join` is true, rows that a TUI may have broken a word across are
    /// joined: the upper row's text up to the break is followed by the
    /// lower row's text, without the blanks and frame between them.
    fn build(
        self: *Text,
        alloc: Allocator,
        source: anytype,
        join: bool,
    ) Allocator.Error!void {
        const rows = source.len();

        // The column the current row's text starts at, past the frame of
        // a row joined to the one above.
        var from: usize = 0;
        var semantic: ?Cell.SemanticContent = null;
        for (0..rows) |y| {
            const cells = source.cells(y);
            const wrap = source.wrap(y);
            const brk: ?Break = if (join and !wrap and y + 1 < rows)
                rowBreak(cells, source.cells(y + 1))
            else
                null;

            const to: usize = if (brk) |b|
                b.end + 1
            else if (wrap)
                cells.len
            else
                @max(from, textEnd(cells));

            for (from..to) |x| {
                const cell = cells[x];
                switch (cell.wide) {
                    .narrow, .wide => {},
                    .spacer_head, .spacer_tail => continue,
                }

                // Prompts, commands and output aren't one text, as in
                // `Screen.selectLine`.
                if (semantic) |v| if (v != cell.semantic_content) {
                    try self.append(alloc, "\n", x, y);
                };
                semantic = cell.semantic_content;

                const cp = cell.codepoint();
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(if (cp == 0) ' ' else cp, &buf) catch {
                    try self.append(alloc, " ", x, y);
                    continue;
                };
                try self.append(alloc, buf[0..len], x, y);
                if (cell.hasGrapheme()) for (source.graphemes(y, x)) |g| {
                    const g_len = std.unicode.utf8Encode(g, &buf) catch continue;
                    try self.append(alloc, buf[0..g_len], x, y);
                };
            }

            if (brk) |b| {
                const above = if (self.joins.items.len > 0)
                    self.joins.items[self.joins.items.len - 1]
                else
                    null;
                try self.joins.append(alloc, .{
                    .at = self.string.items.len,
                    .y = @intCast(y),
                    .rows = b,
                    .same_end_above = if (above) |a|
                        a.y + 1 == y and a.rows.end == b.end
                    else
                        false,
                });
                from = b.start;
            } else {
                from = 0;
                if (!wrap) {
                    try self.append(alloc, "\n", cells.len, y);
                    semantic = null;
                }
            }
        }
    }

    fn append(
        self: *Text,
        alloc: Allocator,
        bytes: []const u8,
        x: usize,
        y: usize,
    ) Allocator.Error!void {
        try self.string.appendSlice(alloc, bytes);
        try self.map.appendNTimes(alloc, .{
            .x = @intCast(x),
            .y = @intCast(y),
        }, bytes.len);
    }

    /// The joins inside bytes `start..end` of the string, which have
    /// text from both rows on either side.
    fn joinsIn(self: *const Text, start: usize, end: usize) []const Join {
        const joins = self.joins.items;
        var i: usize = 0;
        while (i < joins.len and joins[i].at <= start) i += 1;
        var j = i;
        while (j < joins.len and joins[j].at < end) j += 1;
        return joins[i..j];
    }
};

/// A place where `Text` joins a row to the row below it.
const Join = struct {
    /// The byte of `Text.string` where the lower row's text starts.
    at: usize,

    /// The index of the upper row.
    y: u32,

    /// How the text sits in the two rows.
    rows: Break,

    /// True if the row above the upper row is joined to it, and its text
    /// ends at the same column.
    same_end_above: bool,
};

/// How a row's text may go on in the row below it. See `rowBreak`.
const Break = struct {
    /// The last column of the upper row's text.
    end: CellCountInt,

    /// The first column of the lower row's text.
    start: CellCountInt,

    /// The blank columns between `end` and the right edge of the upper
    /// row's text: the edge of the screen, or the vertical line its text
    /// is framed by.
    gap: CellCountInt,

    /// True if both rows are framed by vertical lines and `gap` is as
    /// wide as the blank columns between the lower row's left line and
    /// its text: the padding of a box.
    padded: bool,

    /// True if the lower row's text starts with a wide character, which
    /// may not have fit in the last column of the upper row.
    wide: bool,

    /// True if the lower row's text ends at `end` too.
    same_end_below: bool,
};

/// Returns how the text of the row with `upper` cells may go on in the
/// row with `lower` cells below it, if they look like rows a TUI broke a
/// word across: the upper row's text ends near the right edge of the
/// space it's in, and the lower row's text comes after nothing but blanks
/// and vertical lines. Whether a link goes on is up to `Finder`.
fn rowBreak(upper: []const Cell, lower: []const Cell) ?Break {
    const a = layout(upper) orelse return null;
    const b = layout(lower) orelse return null;

    const right = a.frame orelse upper.len;
    const gap = right - a.end - 1;
    if (gap > max_gap) return null;

    // A row framed on the right goes on inside the same frame.
    if (a.frame) |f| {
        if (f >= lower.len or b.start >= f) return null;
        if (lower[f].codepoint() != upper[f].codepoint()) return null;
    }

    // A prompt isn't joined to a command or output.
    const last = if (upper[a.end].wide == .spacer_tail) a.end - 1 else a.end;
    if (upper[last].semantic_content != lower[b.start].semantic_content) return null;

    return .{
        .end = a.end,
        .start = b.start,
        .gap = @intCast(gap),
        .padded = a.frame != null and b.pad != null and b.pad.? == gap,
        .wide = lower[b.start].wide == .wide,
        .same_end_below = b.end == a.end,
    };
}

/// Where a row's text is, between the blanks and vertical lines that
/// frame it.
const Layout = struct {
    /// The first column of text.
    start: CellCountInt,

    /// The last column of text, with the spacer of a wide character.
    end: CellCountInt,

    /// The column of the vertical line right of the text, if any. With
    /// several, such as nested boxes, the one nearest the text.
    frame: ?CellCountInt,

    /// The blank columns between the text and the vertical line left of
    /// it, or null if there is no line.
    pad: ?CellCountInt,
};

fn layout(cells: []const Cell) ?Layout {
    var start: usize = 0;
    var left: ?usize = null;
    while (start < cells.len) : (start += 1) {
        const cell = cells[start];
        if (isBlank(cell)) continue;
        if (isLine(cell.codepoint())) {
            left = start;
            continue;
        }
        break;
    }
    if (start == cells.len) return null;

    var end = cells.len - 1;
    var frame: ?usize = null;
    while (end > start) : (end -= 1) {
        const cell = cells[end];
        if (isBlank(cell)) continue;
        if (isLine(cell.codepoint())) {
            frame = end;
            continue;
        }
        break;
    }

    return .{
        .start = @intCast(start),
        .end = @intCast(end),
        .frame = if (frame) |v| @intCast(v) else null,
        .pad = if (left) |v| @intCast(start - v - 1) else null,
    };
}

/// Returns the column after the last cell with text in `cells`.
fn textEnd(cells: []const Cell) usize {
    var end = cells.len;
    while (end > 0 and !cells[end - 1].hasText() and
        cells[end - 1].wide != .spacer_tail) end -= 1;
    return end;
}

fn isBlank(cell: Cell) bool {
    return switch (cell.wide) {
        .spacer_head => true,
        .spacer_tail => false,
        .narrow, .wide => !cell.hasText() or cell.codepoint() == ' ',
    };
}

/// Returns true if `cp` is a vertical line that TUIs frame text with,
/// such as the side of a box or a quote bar. Box corners and tree
/// branches ("╰", "└", "⎿") aren't: they start a new item.
fn isLine(cp: u21) bool {
    return switch (cp) {
        '|',
        '│', // U+2502
        '┃', // U+2503
        '┆', // U+2506
        '┇', // U+2507
        '┊', // U+250A
        '┋', // U+250B
        '╎', // U+254E
        '╏', // U+254F
        '║', // U+2551
        '▌', // U+258C
        '▍', // U+258D
        '▎', // U+258E
        '▏', // U+258F
        '▐', // U+2590
        '▕', // U+2595
        '⎸', // U+23B8
        '⎹', // U+23B9
        => true,
        else => false,
    };
}

/// Returns true if `str` starts a link of its own: a URL scheme such as
/// "https://", or the start of a relative path such as "./" or "~/". A
/// word broken at a slash ("/src") may go on, though.
fn startsLink(str: []const u8) bool {
    for ([_][]const u8{ "./", "../", "~/", "mailto:" }) |prefix| {
        if (std.mem.startsWith(u8, str, prefix)) return true;
    }

    var i: usize = 0;
    while (i < str.len and std.ascii.isAlphabetic(str[i])) i += 1;
    return i > 0 and std.mem.startsWith(u8, str[i..], "://");
}

/// Returns true if a link across `join`, at bytes `start..end` of `text`,
/// looks like a word a TUI broke there. TUIs wrap text at spaces and
/// only break a word that is longer than a whole row, at the right edge
/// of the space it's in. So:
///
///   - The upper row's text reaches that edge. We know where it is if
///     the text ends at the edge of the screen or of a box, or the rows
///     next to it end at the same column. A wide character that didn't
///     fit leaves one column.
///   - The lower row's text doesn't start right of the link above it.
///   - The link's part in the lower row is longer than the room before
///     its part in the upper row, or the whole word would have fit in
///     the lower row and been moved there.
///   - The lower row's text doesn't start a link of its own.
fn fits(text: *const Text, join: *const Join, start: usize, end: usize) bool {
    const str = text.string.items;
    const map = text.map.items;
    const b = join.rows;

    if (startsLink(str[join.at..end])) return false;

    const edge = b.gap == 0 or
        (b.gap == 1 and b.wide) or
        b.padded or
        b.same_end_below or
        join.same_end_above;
    if (!edge) return false;

    var first = join.at - 1;
    while (first > start and map[first - 1].y == join.y) first -= 1;
    const upper_x = map[first].x;
    if (b.start > upper_x) return false;

    const lower_y = map[join.at].y;
    var last = join.at;
    while (last + 1 < end and map[last + 1].y == lower_y) last += 1;
    const lower_width = map[last].x + 1 - b.start;
    return lower_width > upper_x - b.start;
}

/// Finds links in rows of the screen. See the top of this file.
pub const Finder = struct {
    /// The rows' text, as the terminal has its lines.
    plain: Text,

    /// The rows' text with rows joined where a TUI may have broken a word
    /// across them, or null if there is nowhere to join.
    joined: ?Text,

    /// A link that `find` found: bytes `start..end` of `text.string`.
    pub const Link = struct {
        text: *const Text,
        start: usize,
        end: usize,

        /// The cells of the link, by byte.
        pub fn cells(self: Link) []const Coordinate {
            return self.text.map.items[self.start..self.end];
        }

        /// Returns the cells of the link's part in each row it was
        /// joined across, by byte, in `buf`. If there are more parts
        /// than fit, the last ones are left out.
        pub fn parts(self: Link, buf: [][]const Coordinate) [][]const Coordinate {
            const map = self.text.map.items;
            var len: usize = 0;
            var from = self.start;
            for (self.text.joinsIn(self.start, self.end)) |join| {
                buf[len] = map[from..join.at];
                len += 1;
                from = join.at;
                if (len == buf.len) return buf;
            }
            buf[len] = map[from..self.end];
            return buf[0 .. len + 1];
        }
    };

    /// Builds the text of the rows of `source`, which must have:
    ///
    ///   - `len() usize`: the number of rows.
    ///   - `cells(y: usize) []const Cell`: the cells of row y.
    ///   - `wrap(y: usize) bool`: true if row y soft-wraps.
    ///   - `graphemes(y: usize, x: usize) []const u21`: the codepoints
    ///     after the first of the cell at x in row y.
    pub fn init(alloc: Allocator, source: anytype) Allocator.Error!Finder {
        var plain: Text = .{};
        errdefer plain.deinit(alloc);
        try plain.build(alloc, source, false);

        const any = for (0..source.len() -| 1) |y| {
            if (source.wrap(y)) continue;
            if (rowBreak(source.cells(y), source.cells(y + 1)) != null) break true;
        } else false;
        if (!any) return .{ .plain = plain, .joined = null };

        var joined: Text = .{};
        errdefer joined.deinit(alloc);
        try joined.build(alloc, source, true);
        return .{ .plain = plain, .joined = joined };
    }

    pub fn deinit(self: *Finder, alloc: Allocator) void {
        self.plain.deinit(alloc);
        if (self.joined) |*v| v.deinit(alloc);
    }

    /// Appends the links that `regex` matches to `result`. If `point` is
    /// set, only the link containing it is found.
    ///
    /// `paths` is set for the default URL regex, whose matches
    /// `url.linkLen` knows how to read: path matches are trimmed to what
    /// exists on disk, and links are joined across rows a TUI broke them
    /// over. Links of other regexes end at the end of a line.
    pub fn find(
        self: *const Finder,
        alloc: Allocator,
        io: std.Io,
        regex: *oni.Regex,
        paths: ?url.PathContext,
        point: ?Coordinate,
        result: *std.ArrayList(Link),
    ) !void {
        const first = result.items.len;
        if (paths) |ctx| if (self.joined) |*text| {
            try findJoined(text, alloc, io, regex, ctx, point, result);
        };
        const joined = result.items.len - first;

        const text = &self.plain;
        const str = text.string.items;
        var offset: usize = 0;
        while (offset < str.len) {
            var region = regex.search(str[offset..], .{}) catch |err| switch (err) {
                error.Mismatch => break,
                else => return err,
            };
            defer region.deinit();

            const start = offset + @as(usize, @intCast(region.starts()[0]));
            var end = offset + @as(usize, @intCast(region.ends()[0]));
            offset = @max(end, start + 1);
            if (point) |p| if (!contains(text.map.items[start..end], p)) continue;

            if (paths) |ctx| {
                // If we keep less than the match, the rest may hold
                // another link, so we search it next.
                const len = url.linkLen(io, str[start..end], ctx) orelse continue;
                end = start + len;
                offset = @max(end, start + 1);
                if (point) |p| if (!contains(text.map.items[start..end], p)) continue;
            }

            // A link joined across rows replaces its parts.
            const link: Link = .{ .text = text, .start = start, .end = end };
            if (overlaps(result.items[first..][0..joined], link)) continue;
            try result.append(alloc, link);
        }
    }

    fn findJoined(
        text: *const Text,
        alloc: Allocator,
        io: std.Io,
        regex: *oni.Regex,
        paths: url.PathContext,
        point: ?Coordinate,
        result: *std.ArrayList(Link),
    ) !void {
        const str = text.string.items;
        var offset: usize = 0;
        while (offset < str.len) {
            var region = regex.search(str[offset..], .{}) catch |err| switch (err) {
                error.Mismatch => break,
                else => return err,
            };
            defer region.deinit();

            const start = offset + @as(usize, @intCast(region.starts()[0]));
            const end = offset + @as(usize, @intCast(region.ends()[0]));
            offset = @max(end, start + 1);

            // Links within a row are found in the plain text.
            const joins = text.joinsIn(start, end);
            if (joins.len == 0) continue;
            if (point) |p| if (!contains(text.map.items[start..end], p)) continue;

            const len = joinedLen(text, io, paths, start, end, joins) orelse {
                // The lower row may start a link that goes on further.
                offset = joins[0].at;
                continue;
            };
            offset = start + len;

            const link: Link = .{ .text = text, .start = start, .end = start + len };
            if (point) |p| if (!contains(link.cells(), p)) continue;
            try result.append(alloc, link);
        }
    }

    /// Returns how many bytes of the match at `start..end` of `text`,
    /// which goes across `joins`, are a link that goes across at least
    /// the first of them, or null if there is no such link.
    fn joinedLen(
        text: *const Text,
        io: std.Io,
        paths: url.PathContext,
        start: usize,
        end: usize,
        joins: []const Join,
    ) ?usize {
        const match = text.string.items[start..end];

        // A path that exists across a join is a link across it, even if
        // we don't know where the TUI's right edge is.
        var ends: [url.max_ends]usize = undefined;
        const n = @min(joins.len, ends.len);
        for (joins[0..n], ends[0..n]) |join, *v| v.* = join.at - start;
        const len = switch (url.pathOnDisk(io, match, paths, ends[0..n])) {
            .len => |len| len,

            // Otherwise the link ends at the first join it doesn't fit.
            .unchecked, .missing => len: {
                var cut = end;
                for (joins) |*join| if (!fits(text, join, start, end)) {
                    cut = join.at;
                    break;
                };
                break :len url.linkLen(io, match[0 .. cut - start], paths) orelse
                    return null;
            },
        };

        if (start + len <= joins[0].at) return null;
        return len;
    }
};

fn contains(cells: []const Coordinate, point: Coordinate) bool {
    for (cells) |cell| if (cell.eql(point)) return true;
    return false;
}

fn overlaps(links: []const Finder.Link, link: Finder.Link) bool {
    for (links) |other| {
        for (link.cells()) |cell| if (contains(other.cells(), cell)) return true;
    }
    return false;
}

/// The rows of a screen around a pin, as a source for `Finder`: the line
/// the pin is on, with its soft-wrapped rows, and the lines a TUI may
/// have broken a link across into it.
pub const ScreenRows = struct {
    /// The first cell of each row.
    pins: []terminal.Pin,

    /// The index of the pin's row in `pins`.
    y: usize,

    pub fn init(alloc: Allocator, pin: terminal.Pin) Allocator.Error!ScreenRows {
        var above: std.ArrayList(terminal.Pin) = .empty;
        defer above.deinit(alloc);
        var below: std.ArrayList(terminal.Pin) = .empty;
        defer below.deinit(alloc);

        var row = pin;
        row.x = 0;

        var top = row;
        var joins: usize = 0;
        while (top.up(1)) |up| {
            if (!up.rowAndCell().row.wrap) {
                if (joins == max_joins or
                    rowBreak(pinCells(up), pinCells(top)) == null) break;
                joins += 1;
            }
            try above.append(alloc, up);
            top = up;
        }

        var bottom = row;
        joins = 0;
        while (bottom.down(1)) |down| {
            if (!bottom.rowAndCell().row.wrap) {
                if (joins == max_joins or
                    rowBreak(pinCells(bottom), pinCells(down)) == null) break;
                joins += 1;
            }
            try below.append(alloc, down);
            bottom = down;
        }

        const pins = try alloc.alloc(terminal.Pin, above.items.len + 1 + below.items.len);
        for (above.items, 0..) |p, i| pins[above.items.len - 1 - i] = p;
        pins[above.items.len] = row;
        @memcpy(pins[above.items.len + 1 ..], below.items);
        return .{ .pins = pins, .y = above.items.len };
    }

    pub fn deinit(self: *ScreenRows, alloc: Allocator) void {
        alloc.free(self.pins);
    }

    /// Returns the cell, as `Finder` sees it, at column `x` of the row of
    /// the pin given to `init`.
    pub fn coordinate(self: *const ScreenRows, x: CellCountInt) Coordinate {
        return .{ .x = x, .y = @intCast(self.y) };
    }

    /// Returns the pin of a cell as `Finder` sees it.
    pub fn pinAt(self: *const ScreenRows, cell: Coordinate) terminal.Pin {
        var result = self.pins[cell.y];
        result.x = cell.x;
        return result;
    }

    pub fn len(self: *const ScreenRows) usize {
        return self.pins.len;
    }

    pub fn cells(self: *const ScreenRows, y: usize) []const Cell {
        return pinCells(self.pins[y]);
    }

    pub fn wrap(self: *const ScreenRows, y: usize) bool {
        return self.pins[y].rowAndCell().row.wrap;
    }

    pub fn graphemes(self: *const ScreenRows, y: usize, x: usize) []const u21 {
        const p = self.pins[y];
        const page = p.node.page();
        return page.lookupGrapheme(&page.getCells(p.rowAndCell().row)[x]) orelse &.{};
    }

    fn pinCells(p: terminal.Pin) []const Cell {
        return p.node.page().getCells(p.rowAndCell().row);
    }
};

/// Returns the link that the default URL regex finds at column `x` of
/// row `y` of the viewport of `t`, or null.
fn testLink(
    alloc: Allocator,
    t: *terminal.Terminal,
    x: CellCountInt,
    y: u32,
    paths: url.PathContext,
) !?[]const u8 {
    var re = try oni.Regex.init(
        url.regex,
        .{},
        oni.Encoding.utf8,
        oni.Syntax.default,
        null,
    );
    defer re.deinit();

    const pin = t.screens.active.pages.pin(.{ .viewport = .{ .x = x, .y = y } }).?;
    var rows: ScreenRows = try .init(alloc, pin);
    defer rows.deinit(alloc);
    var finder: Finder = try .init(alloc, &rows);
    defer finder.deinit(alloc);
    var found: std.ArrayList(Finder.Link) = .empty;
    defer found.deinit(alloc);
    try finder.find(alloc, std.testing.io, &re, paths, rows.coordinate(x), &found);
    if (found.items.len == 0) return null;
    const link = found.items[0];
    return try alloc.dupe(u8, link.text.string.items[link.start..link.end]);
}

fn expectLink(
    t: *terminal.Terminal,
    x: CellCountInt,
    y: u32,
    paths: url.PathContext,
    expected: ?[]const u8,
) !void {
    const testing = std.testing;
    const alloc = testing.allocator;
    const actual = try testLink(alloc, t, x, y, paths);
    defer if (actual) |v| alloc.free(v);
    if (expected) |e| {
        try testing.expectEqualStrings(e, actual orelse {
            std.debug.print("expected {s} at {},{}, got null\n", .{ e, x, y });
            return error.TestExpectedEqual;
        });
    } else if (actual) |a| {
        std.debug.print("expected null at {},{}, got {s}\n", .{ x, y, a });
        return error.TestExpectedEqual;
    }
}

fn testTerminal(cols: CellCountInt, str: []const u8) !terminal.Terminal {
    const testing = std.testing;
    try oni.testing.ensureInit();
    var t: terminal.Terminal = try .init(testing.io, testing.allocator, .{
        .cols = cols,
        .rows = 6,
    });
    errdefer t.deinit(testing.allocator);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice(str);
    return t;
}

test "Finder joins a URL broken over indented rows" {
    var t = try testTerminal(20, "• https://example.co\r\n" ++
        "  m/a/b and more");
    defer t.deinit(std.testing.allocator);

    try expectLink(&t, 5, 0, .{}, "https://example.com/a/b");
    try expectLink(&t, 3, 1, .{}, "https://example.com/a/b");
    try expectLink(&t, 9, 1, .{}, null);
}

test "Finder joins a URL broken inside a box" {
    var t = try testTerminal(20, "│ https://example. │\r\n" ++
        "│ com/x            │\r\n" ++
        "╰──────────────────╯");
    defer t.deinit(std.testing.allocator);

    try expectLink(&t, 4, 0, .{}, "https://example.com/x");
    try expectLink(&t, 2, 1, .{}, "https://example.com/x");
}

test "Finder doesn't join words wrapped at a space" {
    var t = try testTerminal(20, "see https://ab.com/x\r\n" ++
        "for more");
    defer t.deinit(std.testing.allocator);

    try expectLink(&t, 6, 0, .{}, "https://ab.com/x");
    try expectLink(&t, 1, 1, .{}, null);
}

test "Finder doesn't join a URL short of the right edge" {
    var t = try testTerminal(20, "  https://ab.com/x\r\n" ++
        "  yz");
    defer t.deinit(std.testing.allocator);

    try expectLink(&t, 4, 0, .{}, "https://ab.com/x");
    try expectLink(&t, 2, 1, .{}, null);
}

test "Finder joins a URL over rows that end at the same column" {
    var t = try testTerminal(20, "  https://example.\r\n" ++
        "  com/aaaaaaaaaaaa\r\n" ++
        "  bb");
    defer t.deinit(std.testing.allocator);

    try expectLink(&t, 4, 0, .{}, "https://example.com/aaaaaaaaaaaabb");
    try expectLink(&t, 4, 1, .{}, "https://example.com/aaaaaaaaaaaabb");
    try expectLink(&t, 2, 2, .{}, "https://example.com/aaaaaaaaaaaabb");
}

test "Finder doesn't join a new link" {
    var t = try testTerminal(20, "https://example.com/\r\n" ++
        "https://b.com\r\n" ++
        "  ./src/aaa.zig\r\n" ++
        "  ./src/bbb.zig");
    defer t.deinit(std.testing.allocator);

    try expectLink(&t, 4, 0, .{}, "https://example.com/");
    try expectLink(&t, 4, 1, .{}, "https://b.com");
    try expectLink(&t, 4, 2, .{ .remote = true }, "./src/aaa.zig");
    try expectLink(&t, 4, 3, .{ .remote = true }, "./src/bbb.zig");
}

test "Finder joins paths that exist" {
    const testing = std.testing;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src/renderer");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/renderer/link.zig", .data = "" });
    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    const paths: url.PathContext = .{ .pwd = root };

    // Short of the edge, by the TUI's padding
    {
        var t = try testTerminal(20, "  - src/renderer/l\r\n" ++
            "    ink.zig에서");
        defer t.deinit(testing.allocator);
        try expectLink(&t, 6, 0, paths, "src/renderer/link.zig");
        try expectLink(&t, 5, 1, paths, "src/renderer/link.zig");
    }

    // A path that ends at the edge isn't joined to the next row's text.
    {
        var t = try testTerminal(20, "open ./src/renderer/\r\n" ++
            "done");
        defer t.deinit(testing.allocator);
        try expectLink(&t, 7, 0, paths, "./src/renderer/");
        try expectLink(&t, 1, 1, paths, null);
    }
}
