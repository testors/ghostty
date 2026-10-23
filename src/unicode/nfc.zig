//! Canonical composition of decomposed Unicode sequences.
//!
//! macOS stores filenames in NFD (decomposed) form, so Hangul arrives as
//! conjoining jamo and accented Latin letters arrive as a base letter
//! plus a combining mark. Many fonts (including D2Coding) only contain
//! the precomposed codepoints, so font selection falls back to a
//! different font for every such cluster even though the shaper would
//! have composed them later.
//!
//! The terminal uses `compose` to turn these sequences back into their
//! precomposed form at the moment a codepoint is attached to a cell (see
//! Terminal.print). Composing pairwise at that point means the result
//! does not depend on how the PTY output was chunked or which print
//! path handled it, and already-composed text costs nothing.
//!
//! This is deliberately not a full NFC normalizer:
//!
//!   * A standalone codepoint is never rewritten. Singleton
//!     decompositions such as CJK compatibility ideographs (for example
//!     the KS X 1001 Hanja that encode a specific reading) keep their
//!     codepoint, which full NFC would replace.
//!   * Combining marks are not canonically reordered. NFD input, which
//!     is what filesystems produce, is already in canonical order and
//!     therefore composes to the same result NFC would give.
const std = @import("std");
const assert = std.debug.assert;
const uucode = @import("uucode");

const log = std.log.scoped(.unicode);

/// Hangul syllable composition constants from The Unicode Standard,
/// section 3.12 "Conjoining Jamo Behavior".
const SBase: u21 = 0xAC00;
const LBase: u21 = 0x1100;
const VBase: u21 = 0x1161;
const TBase: u21 = 0x11A7;
const LCount: u21 = 19;
const VCount: u21 = 21;
const TCount: u21 = 28;
const NCount: u21 = VCount * TCount;
const SCount: u21 = LCount * NCount;

/// A primary composite: a starter and a second codepoint that compose
/// into a single codepoint.
const Composition = struct {
    starter: u21,
    second: u21,
    composite: u21,

    fn lessThan(_: void, a: Composition, b: Composition) bool {
        if (a.starter != b.starter) return a.starter < b.starter;
        return a.second < b.second;
    }
};

/// Upper bound on the number of primary composites. Unicode 16 defines
/// 941 (Hangul is algorithmic and not counted), so this leaves ample
/// room for future versions.
const max_compositions = 2048;

/// The table of primary composites, sorted by (starter, second) for
/// binary search. It is built from uucode's decomposition data on first
/// use because iterating all of Unicode at comptime is too slow.
var table_buf: [max_compositions]Composition = undefined;
var table_len: usize = 0;

/// Initialization state of the table: 0 = not built, 1 = being built
/// by some thread, 2 = ready. Readers only pay an acquire load once the
/// table is ready.
var table_state = std.atomic.Value(u8).init(0);

fn getTable() []const Composition {
    while (true) {
        switch (table_state.load(.acquire)) {
            2 => return table_buf[0..table_len],
            0 => if (table_state.cmpxchgStrong(0, 1, .acquire, .acquire) == null) {
                buildTable();
                table_state.store(2, .release);
                return table_buf[0..table_len];
            },
            else => std.atomic.spinLoopHint(),
        }
    }
}

fn buildTable() void {
    var len: usize = 0;
    var cp: u21 = 0;
    while (cp <= 0x10FFFF) : (cp += 1) {
        // Hangul syllables are composed algorithmically.
        if (cp >= SBase and cp < SBase + SCount) continue;

        if (uucode.get(.decomposition_type, cp) != .canonical) continue;

        var buf: [1]u21 = undefined;
        const mapping = uucode.get(.decomposition_mapping, cp).with(&buf, cp);

        // Singletons never recompose. Full NFC rewrites them to their
        // decomposition, which we intentionally don't do.
        if (mapping.len != 2) continue;

        // uucode's is_composition_exclusion is the explicit list from
        // CompositionExclusions.txt. The derived Full_Composition_Exclusion
        // property additionally covers singletons (handled above) and
        // non-starter decompositions (handled below), so together these
        // checks leave exactly the primary composites.
        if (uucode.get(.is_composition_exclusion, cp)) continue;
        if (uucode.get(.canonical_combining_class, mapping[0]) != 0) continue;

        if (len == table_buf.len) {
            log.err("primary composite table is full, composition will be incomplete", .{});
            break;
        }
        table_buf[len] = .{
            .starter = mapping[0],
            .second = mapping[1],
            .composite = cp,
        };
        len += 1;
    }

    std.mem.sortUnstable(Composition, table_buf[0..len], {}, Composition.lessThan);
    table_len = len;
}

/// Look up the primary composite for a starter and second codepoint.
fn composePair(starter: u21, second: u21) ?u21 {
    const table = getTable();
    var lo: usize = 0;
    var hi: usize = table.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const c = table[mid];
        if (c.starter == starter and c.second == second) return c.composite;
        if (c.starter < starter or (c.starter == starter and c.second < second)) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return null;
}

/// Compose two Hangul jamo, or an LV syllable and a trailing consonant.
fn composeHangul(a: u21, b: u21) ?u21 {
    // Leading consonant + vowel -> LV syllable.
    if (a >= LBase and a < LBase + LCount and
        b >= VBase and b < VBase + VCount)
    {
        const l = a - LBase;
        const v = b - VBase;
        return SBase + (l * VCount + v) * TCount;
    }

    // LV syllable + trailing consonant -> LVT syllable. TBase itself is
    // a filler, not a trailing consonant.
    if (a >= SBase and a < SBase + SCount and
        (a - SBase) % TCount == 0 and
        b > TBase and b < TBase + TCount)
    {
        return a + (b - TBase);
    }

    return null;
}

/// Compose `second` onto `starter`. Returns the precomposed codepoint if
/// the pair is a Hangul jamo sequence or a primary composite, and null
/// otherwise. Blocking rules don't apply here: callers only compose a
/// codepoint onto a cell that holds exactly one codepoint, so the pair
/// is always adjacent.
pub fn compose(starter: u21, second: u21) ?u21 {
    if (composeHangul(starter, second)) |s| return s;

    // Every non-Hangul primary composite has a combining mark or an
    // Indic/Myanmar vowel sign as its second codepoint, all of which are
    // at or above the Combining Diacritical Marks block.
    if (second < 0x0300) return null;

    return composePair(starter, second);
}

test "nfc: table size" {
    const table = getTable();
    try std.testing.expect(table.len >= 900);
    try std.testing.expect(table.len < max_compositions);
}

test "nfc: hangul" {
    const testing = std.testing;

    // L + V -> LV (무)
    try testing.expectEqual(@as(?u21, 0xBB34), compose(0x1106, 0x116E));
    // LV + T -> LVT (문)
    try testing.expectEqual(@as(?u21, 0xBB38), compose(0xBB34, 0x11AB));
    // LVT + T, LV + L, V + T: nothing composes
    try testing.expectEqual(@as(?u21, null), compose(0xBB38, 0x11AB));
    try testing.expectEqual(@as(?u21, null), compose(0xBB34, 0x110C));
    try testing.expectEqual(@as(?u21, null), compose(0x116E, 0x11AB));
    // The T filler is not a trailing consonant
    try testing.expectEqual(@as(?u21, null), compose(0xBB34, 0x11A7));
}

test "nfc: latin combining" {
    const testing = std.testing;
    // e + combining acute -> é
    try testing.expectEqual(@as(?u21, 0x00E9), compose('e', 0x0301));
    // é + combining acute: no such precomposed letter
    try testing.expectEqual(@as(?u21, null), compose(0x00E9, 0x0301));
}

test "nfc: second codepoint with combining class zero" {
    const testing = std.testing;
    // ORIYA VOWEL SIGN E + ORIYA AI LENGTH MARK -> ORIYA VOWEL SIGN AI
    try testing.expectEqual(@as(?u21, 0x0B48), compose(0x0B47, 0x0B56));
    // MYANMAR LETTER U + MYANMAR VOWEL SIGN II -> MYANMAR LETTER UU
    try testing.expectEqual(@as(?u21, 0x1026), compose(0x1025, 0x102E));
}

test "nfc: japanese voiced sound mark" {
    // HIRAGANA KA + COMBINING VOICED SOUND MARK -> HIRAGANA GA
    try std.testing.expectEqual(@as(?u21, 0x304C), compose(0x304B, 0x3099));
}

test "nfc: composition exclusions" {
    const testing = std.testing;
    // DEVANAGARI KA + NUKTA decomposes from U+0958, which is excluded
    // from recomposition.
    try testing.expectEqual(@as(?u21, null), compose(0x0915, 0x093C));
    // U+0344 has a non-starter decomposition and must never be produced.
    try testing.expectEqual(@as(?u21, null), compose(0x0308, 0x0301));
}

test "nfc: no composition" {
    const testing = std.testing;
    try testing.expectEqual(@as(?u21, null), compose('a', 'b'));
    try testing.expectEqual(@as(?u21, null), compose(0x6A02, 0x0301));
}
