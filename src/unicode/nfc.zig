//! Unicode NFC (Normalization Form C) normalization.
//!
//! This is used by the terminal to normalize text before it is stored in
//! the grid. macOS stores filenames in NFD (decomposed) form, which means
//! Hangul is represented as conjoining jamo. Many fonts (including
//! D2Coding) only contain precomposed Hangul syllables, so without
//! normalization the terminal has to fall back to a different font for
//! every jamo. Normalizing to NFC lets the configured font render the
//! text.
const std = @import("std");
const uucode = @import("uucode");

const Allocator = std.mem.Allocator;

/// Hangul syllable composition constants from Unicode 3.12.
const SBase = 0xAC00;
const LBase = 0x1100;
const VBase = 0x1161;
const TBase = 0x11A7;
const LCount = 19;
const VCount = 21;
const TCount = 28;
const NCount = VCount * TCount;
const SCount = LCount * NCount;

/// A primary composite: a starter and a combining mark that compose into
/// a single codepoint.
const Composition = struct {
    starter: u21,
    mark: u21,
    composite: u21,
};

/// The primary composites from the Unicode Character Database. This is
/// built lazily on first use from uucode's canonical decomposition data.
/// Hangul is handled algorithmically and is not in this table.
var compositions_lock = std.atomic.Value(bool).init(false);
var compositions: ?[]const Composition = null;

fn getCompositions() []const Composition {
    // Simple spinlock for one-time initialization. This is only ever
    // contended on the very first normalization in a process.
    while (compositions_lock.swap(true, .acquire)) {
        std.atomic.spinLoopHint();
    }
    defer compositions_lock.store(false, .release);

    if (compositions) |c| return c;

    const alloc = std.heap.page_allocator;
    var list: std.ArrayListUnmanaged(Composition) = .empty;

    var cp: u21 = 0;
    while (cp <= 0x10FFFF) : (cp += 1) {
        // Hangul syllables have algorithmic decompositions and are not
        // in the UCD decomposition data.
        if (cp >= SBase and cp < SBase + SCount) continue;

        if (uucode.get(.decomposition_type, cp) != .canonical) continue;
        if (uucode.get(.is_composition_exclusion, cp)) continue;

        var buf: [1]u21 = undefined;
        const mapping = uucode.get(.decomposition_mapping, cp).with(&buf, cp);
        if (mapping.len != 2) continue;

        list.append(alloc, .{
            .starter = mapping[0],
            .mark = mapping[1],
            .composite = cp,
        }) catch unreachable;
    }

    // Sort by starter then mark so we can binary search.
    std.mem.sortUnstable(Composition, list.items, {}, struct {
        fn lessThan(_: void, a: Composition, b: Composition) bool {
            if (a.starter != b.starter) return a.starter < b.starter;
            return a.mark < b.mark;
        }
    }.lessThan);

    compositions = list.toOwnedSlice(alloc) catch unreachable;
    return compositions.?;
}

/// Look up the primary composite for a starter and mark pair.
fn composePair(starter: u21, mark: u21) ?u21 {
    const table = getCompositions();
    var lo: usize = 0;
    var hi: usize = table.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const c = table[mid];
        if (c.starter < starter or (c.starter == starter and c.mark < mark)) {
            lo = mid + 1;
        } else if (c.starter == starter and c.mark == mark) {
            return c.composite;
        } else {
            hi = mid;
        }
    }
    return null;
}

/// Decompose a Hangul syllable into its jamo. Returns the number of
/// codepoints written to `out`, or zero if `cp` is not a syllable.
fn decomposeHangul(cp: u21, out: *[3]u21) usize {
    if (cp < SBase or cp >= SBase + SCount) return 0;

    const s = cp - SBase;
    out[0] = LBase + s / NCount;
    out[1] = VBase + (s % NCount) / TCount;
    const t = s % TCount;
    if (t == 0) return 2;
    out[2] = TBase + t;
    return 3;
}

/// Compose two Hangul jamo. Returns the composed syllable or null.
fn composeHangul(a: u21, b: u21) ?u21 {
    // Leading consonant + vowel.
    if (a >= LBase and a < LBase + LCount and
        b >= VBase and b < VBase + VCount)
    {
        const l = a - LBase;
        const v = b - VBase;
        return SBase + (l * VCount + v) * TCount;
    }

    // LV syllable + trailing consonant.
    if (a >= SBase and a < SBase + SCount and
        (a - SBase) % TCount == 0 and
        b > TBase and b < TBase + TCount)
    {
        return a + (b - TBase);
    }

    return null;
}

/// Recursively decompose a codepoint into its canonical decomposition.
fn decompose(
    alloc: Allocator,
    out: *std.ArrayListUnmanaged(u21),
    cp: u21,
) !void {
    var hbuf: [3]u21 = undefined;
    const hlen = decomposeHangul(cp, &hbuf);
    if (hlen > 0) {
        try out.appendSlice(alloc, hbuf[0..hlen]);
        return;
    }

    if (uucode.get(.decomposition_type, cp) == .canonical) {
        var buf: [1]u21 = undefined;
        const mapping = uucode.get(.decomposition_mapping, cp).with(&buf, cp);
        if (mapping.len > 0) {
            for (mapping) |m| try decompose(alloc, out, m);
            return;
        }
    }

    try out.append(alloc, cp);
}

/// Canonically order combining marks by their combining class. This is a
/// stable insertion sort, which is fine because combining sequences are
/// short.
fn canonicalOrder(cps: []u21) void {
    var i: usize = 1;
    while (i < cps.len) : (i += 1) {
        const ccc = uucode.get(.canonical_combining_class, cps[i]);
        if (ccc == 0) continue;

        var j = i;
        while (j > 0) {
            const prev_ccc = uucode.get(.canonical_combining_class, cps[j - 1]);
            if (prev_ccc == 0 or prev_ccc <= ccc) break;
            std.mem.swap(u21, &cps[j], &cps[j - 1]);
            j -= 1;
        }
    }
}

/// Compose a canonically ordered sequence in place. Returns the new
/// length.
fn compose(cps: []u21) usize {
    var out_len: usize = 0;
    var starter_idx: ?usize = null;
    var last_ccc: u8 = 0;

    for (cps) |cp| {
        const ccc = uucode.get(.canonical_combining_class, cp);

        if (starter_idx) |si| {
            // Hangul composition only applies when the starter is the
            // immediately preceding character.
            if (last_ccc == 0) {
                if (composeHangul(cps[si], cp)) |composite| {
                    cps[si] = composite;
                    continue;
                }
            }

            // General composition is blocked if there is an intervening
            // character with a combining class greater than or equal to
            // this one.
            if (ccc != 0 and (last_ccc == 0 or last_ccc < ccc)) {
                if (composePair(cps[si], cp)) |composite| {
                    cps[si] = composite;
                    continue;
                }
            }
        }

        if (ccc == 0) {
            starter_idx = out_len;
            last_ccc = 0;
        } else {
            last_ccc = ccc;
        }

        cps[out_len] = cp;
        out_len += 1;
    }

    return out_len;
}

/// Normalize a sequence of codepoints to NFC. The returned slice is
/// allocated with `alloc` and must be freed by the caller.
pub fn normalize(alloc: Allocator, input: []const u21) ![]u21 {
    // Fast path: ASCII is already NFC.
    var ascii = true;
    for (input) |cp| {
        if (cp >= 0x80) {
            ascii = false;
            break;
        }
    }
    if (ascii) return alloc.dupe(u21, input);

    var decomposed: std.ArrayListUnmanaged(u21) = .empty;
    defer decomposed.deinit(alloc);

    for (input) |cp| try decompose(alloc, &decomposed, cp);
    canonicalOrder(decomposed.items);

    const len = compose(decomposed.items);
    return alloc.dupe(u21, decomposed.items[0..len]);
}

/// Normalize a sequence of u32 codepoints to NFC. This is a convenience
/// wrapper for callers that use u32 codepoints (such as the terminal
/// parser). The returned slice is allocated with `alloc`.
pub fn normalizeU32(alloc: Allocator, input: []const u32) ![]u32 {
    var u21_input = try alloc.alloc(u21, input.len);
    defer alloc.free(u21_input);
    for (input, 0..) |cp, i| u21_input[i] = @intCast(cp);

    const normalized = try normalize(alloc, u21_input);
    defer alloc.free(normalized);

    const result = try alloc.alloc(u32, normalized.len);
    for (normalized, 0..) |cp, i| result[i] = cp;
    return result;
}

test "nfc: hangul" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // 무제 폴더 in NFD.
    const nfd = [_]u21{
        0x1106, 0x116E, // 무
        0x110C, 0x1166, // 제
        0x0020,
        0x1111, 0x1169, 0x11AF, // 폴
        0x1103, 0x1165, // 더
    };
    const result = try normalize(alloc, &nfd);
    defer alloc.free(result);

    const expected = [_]u21{ 0xBB34, 0xC81C, 0x0020, 0xD3F4, 0xB354 };
    try testing.expectEqualSlices(u21, &expected, result);
}

test "nfc: latin combining" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // e + combining acute -> é
    const input = [_]u21{ 'e', 0x0301 };
    const result = try normalize(alloc, &input);
    defer alloc.free(result);

    try testing.expectEqualSlices(u21, &[_]u21{0x00E9}, result);
}

test "nfc: ascii" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const input = [_]u21{ 'h', 'e', 'l', 'l', 'o' };
    const result = try normalize(alloc, &input);
    defer alloc.free(result);

    try testing.expectEqualSlices(u21, &input, result);
}
