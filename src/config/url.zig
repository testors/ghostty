const std = @import("std");
const oni = @import("oniguruma");

/// Default URL/path regex. This is used to detect URLs and file paths in
/// terminal output.
///
/// This is here in the config package because one day the matchers will be
/// configurable and this will be a default.
///
/// For scheme URLs, this regex is liberal in what it accepts after the scheme,
/// with exceptions for URLs ending with . or ). Although such URLs are
/// perfectly valid, it is common for text to contain URLs surrounded by
/// parentheses (such as in Markdown links) or at the end of sentences.
/// Therefore, this regex excludes them as follows:
///
/// 1. Do not match regexes ending with .
/// 2. Do not match regexes ending with ), except for ones which contain a (
///    without a subsequent )
///
/// Rule 2 means that we handle the following two cases:
///
///   "https://en.wikipedia.org/wiki/Rust_(video_game)" (include parens)
///   "(https://example.com)" (do not include the parens)
///
/// There are many complicated cases where these heuristics break down, but
/// handling them well requires a non-regex approach.
const url_schemes =
    \\https?://|mailto:|ftp://|file:|ssh:|git://|ssh://|tel:|magnet:|ipfs://|ipns://|gemini://|gopher://|news:
;

const ipv6_url_pattern =
    \\(?:\[[:0-9a-fA-F]+(?:[:0-9a-fA-F]*)+\](?::[0-9]+)?)
;

const scheme_url_chars =
    \\[\w\-.~:/?#@!$&*+,;=%]
;

const path_chars =
    \\[\w\-.~:\/?#@!$&*+;=%]
;

const optional_bracketed_word_suffix =
    \\(?:[\(\[]\w*[\)\]])?
;

const no_trailing_punctuation =
    \\(?<![,.])
;

const no_trailing_colon =
    \\(?<!:)
;

const dotted_path_lookahead =
    \\(?=[\w\-.~:\/?#@!$&*+;=%]*\.)
;

const non_dotted_path_lookahead =
    \\(?![\w\-.~:\/?#@!$&*+;=%]*\.)
;

const dotted_path_space_segments =
    \\(?:(?<!:) (?!\w+:\/\/)(?!\.{0,2}\/)(?!~\/)[\w\-.~:\/?#@!$&*+;=%]*[\/.])*
;

const any_path_space_segments =
    \\(?:(?<!:) (?!\w+:\/\/)(?!\.{0,2}\/)(?!~\/)[\w\-.~:\/?#@!$&*+;=%]+)*
;

// Branch 1: URLs with explicit schemes (http, mailto, ftp, etc.).
const scheme_url_branch =
    "(?:" ++ url_schemes ++ ")" ++
    "(?:" ++ ipv6_url_pattern ++ "|" ++ scheme_url_chars ++ "+" ++ optional_bracketed_word_suffix ++ ")+" ++
    no_trailing_punctuation;

const rooted_or_relative_path_prefix =
    \\(?:\.\.\/|\.\/|(?<!\w)~\/|(?:[\w][\w\-.]*\/)*(?<!\w)\$[A-Za-z_]\w*\/|\.[\w][\w\-.]*\/|(?<![\w~\/])\/(?!\/))
;

// Branch 2: Absolute paths and dot-relative paths (/, ./, ../).
// A dotted segment is treated as file-like, while the undotted case stays
// broad to capture directory-like paths with spaces.
const rooted_or_relative_path_branch =
    rooted_or_relative_path_prefix ++
    "(?:" ++
    dotted_path_lookahead ++
    path_chars ++ "+" ++
    dotted_path_space_segments ++
    no_trailing_colon ++
    "|" ++
    non_dotted_path_lookahead ++
    path_chars ++ "+" ++
    any_path_space_segments ++
    no_trailing_colon ++
    ")";

// Branch 3: Bare relative paths such as src/config/url.zig.
const bare_relative_path_prefix =
    \\(?<!\$\d*)(?<!\w)[\w][\w\-.]*\/
;

const bare_relative_path_branch =
    dotted_path_lookahead ++
    bare_relative_path_prefix ++
    path_chars ++ "+" ++
    no_trailing_colon;

// Branch 4: Bare relative paths without a dot such as src/config. These
// look just like words joined by a slash ("and/or"), so they are only
// links if they exist on disk. See `linkLen`.
const bare_undotted_path_branch =
    bare_relative_path_prefix ++
    path_chars ++ "+" ++
    no_trailing_colon;

pub const regex =
    scheme_url_branch ++
    "|" ++
    rooted_or_relative_path_branch ++
    "|" ++
    bare_relative_path_branch ++
    "|" ++
    bare_undotted_path_branch;

/// What `linkLen` needs to find paths on disk.
pub const PathContext = struct {
    /// The terminal's working directory, for relative paths.
    pwd: ?[]const u8 = null,

    /// The user's home directory, for paths starting with "~/".
    home: ?[]const u8 = null,
};

/// Returns how many bytes of `match`, a match of `regex`, are the link,
/// or null if the match isn't a link.
///
/// The regex can't tell where a path ends in prose. Directory matches
/// take the words after them ("../src for details"), and text glued to
/// the end comes along too, such as a Korean particle ("~/src에서") or
/// the period ending a sentence. Line numbers ("src/main.zig:42:10") name
/// a file that doesn't exist either. So for paths this returns the longest
/// prefix that exists on disk, cutting only at spaces and inside the
/// punctuation, non-ASCII text or ":<number>" parts that end each word.
///
/// If no prefix exists, or the path can't be checked (a relative path
/// with no known pwd, or one using a $VARIABLE), the full match is kept.
/// The exception is bare paths without a dot such as "src/config", which
/// are only links if they exist.
pub fn linkLen(io: std.Io, match: []const u8, ctx: PathContext) ?usize {
    // Scheme URLs ("https://", "mailto:") have a colon before any slash.
    // Paths never do.
    const slash = std.mem.indexOfScalar(u8, match, '/') orelse return match.len;
    if (std.mem.indexOfScalar(u8, match[0..slash], ':') != null) return match.len;
    if (std.mem.indexOfScalar(u8, match, '$') != null) return match.len;

    // A dot makes a bare path look like a file ("src/main.zig"), but not
    // the period ending a sentence.
    const must_exist = switch (match[0]) {
        '/', '.', '~' => false,
        else => std.mem.indexOfScalar(
            u8,
            std.mem.trimEnd(u8, match, trailing_punctuation),
            '.',
        ) == null,
    };
    const fallback: ?usize = if (must_exist) null else match.len;

    const root: PathRoot = if (match[0] == '/')
        .{ .dir = "", .skip = 0 }
    else if (std.mem.startsWith(u8, match, "~/"))
        .{ .dir = ctx.home orelse return fallback, .skip = 1 }
    else
        .{ .dir = ctx.pwd orelse return fallback, .skip = 0 };
    if (root.dir.len > 0 and !std.fs.path.isAbsolute(root.dir)) return fallback;

    if (root.exists(io, match)) return match.len;

    // Walk back one codepoint at a time. `trimming` is true while
    // everything between here and the end of the word could be text
    // that follows the path rather than part of it.
    var trimming = true;
    var i = match.len;
    while (i > slash + 1) {
        var j = i - 1;
        while (j > 0 and match[j] & 0xC0 == 0x80) j -= 1;
        i = j;

        const c = match[j];
        if (c == ' ') {
            trimming = true;
        } else if (trimming and std.ascii.isDigit(c)) {
            // A line or column number after a path, such as ":42" in
            // "src/main.zig:42:10". Skip to its colon, which is tried next.
            var k = j;
            while (k > 0 and std.ascii.isDigit(match[k - 1])) k -= 1;
            if (k > 0 and match[k - 1] == ':') {
                i = k;
                continue;
            }
            trimming = false;
            continue;
        } else if (!trimming or !trailingText(c)) {
            trimming = false;
            continue;
        }

        // Paths don't end with a space, and we never shorten one to
        // just its root, such as "~/" or "../".
        const candidate = match[0..j];
        if (candidate[j - 1] == ' ') continue;
        if (std.mem.indexOfNone(u8, candidate[slash + 1 ..], "./") == null) continue;
        if (root.exists(io, candidate)) return j;
    }

    return fallback;
}

/// Where a path from `linkLen` is found on disk.
const PathRoot = struct {
    /// The absolute directory the path is in, or empty for absolute paths.
    dir: []const u8,

    /// Leading bytes of the path to replace with `dir`, such as "~".
    skip: usize,

    fn exists(self: PathRoot, io: std.Io, path: []const u8) bool {
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        const rest = path[self.skip..];
        writer.writeAll(self.dir) catch return false;
        if (self.dir.len > 0 and rest[0] != '/') writer.writeByte('/') catch return false;
        writer.writeAll(rest) catch return false;
        std.Io.Dir.accessAbsolute(io, writer.buffered(), .{}) catch return false;
        return true;
    }
};

/// Punctuation that can be written right after a path.
const trailing_punctuation = ".:;!?*#@&+=%~";

/// Returns true if `c` can be text written right after a path:
/// punctuation or the first byte of a non-ASCII character.
fn trailingText(c: u8) bool {
    return c >= 0x80 or std.mem.indexOfScalar(u8, trailing_punctuation, c) != null;
}

test "url regex" {
    const testing = std.testing;

    try oni.testing.ensureInit();
    var re = try oni.Regex.init(
        regex,
        .{},
        oni.Encoding.utf8,
        oni.Syntax.default,
        null,
    );
    defer re.deinit();

    // The URL cases to test what our regex matches. Feel free to add to this
    // as we find bugs or just want more coverage.
    const cases = [_]struct {
        input: []const u8,
        expect: []const u8,
        num_matches: usize = 1,
    }{
        .{
            .input = "hello https://example.com world",
            .expect = "https://example.com",
        },
        .{
            .input = "https://example.com/foo(bar) more",
            .expect = "https://example.com/foo(bar)",
        },
        .{
            .input = "https://example.com/foo(bar)baz more",
            .expect = "https://example.com/foo(bar)baz",
        },
        .{
            .input = "Link inside (https://example.com) parens",
            .expect = "https://example.com",
        },
        .{
            .input = "Link period https://example.com. More text.",
            .expect = "https://example.com",
        },
        .{
            .input = "Link trailing comma https://example.com, more text.",
            .expect = "https://example.com",
        },
        .{
            .input = "Link in double quotes \"https://example.com\" and more",
            .expect = "https://example.com",
        },
        .{
            .input = "Link in single quotes 'https://example.com' and more",
            .expect = "https://example.com",
        },
        .{
            .input = "some file with https://google.com https://duckduckgo.com links.",
            .expect = "https://google.com",
        },
        .{
            .input = "and links in it. links https://yahoo.com mailto:test@example.com ssh://1.2.3.4",
            .expect = "https://yahoo.com",
        },
        .{
            .input = "also match http://example.com non-secure links",
            .expect = "http://example.com",
        },
        .{
            .input = "match tel://+12123456789 phone numbers",
            .expect = "tel://+12123456789",
        },
        .{
            .input = "match with query url https://example.com?query=1&other=2 and more text.",
            .expect = "https://example.com?query=1&other=2",
        },
        .{
            .input = "url with dashes [mode 2027](https://github.com/contour-terminal/terminal-unicode-core) for better unicode support",
            .expect = "https://github.com/contour-terminal/terminal-unicode-core",
        },
        .{
            .input = "dot.http://example.com",
            .expect = "http://example.com",
        },
        // weird characters in URL
        .{
            .input = "weird characters https://example.com/~user/?query=1&other=2#hash and more",
            .expect = "https://example.com/~user/?query=1&other=2#hash",
        },
        // square brackets in URL
        .{
            .input = "square brackets https://example.com/[foo] and more",
            .expect = "https://example.com/[foo]",
        },
        // square bracket following url
        .{
            .input = "[13]:TooManyStatements: TempFile#assign_temp_file_to_entity has approx 7 statements [https://example.com/docs/Too-Many-Statements.md]",
            .expect = "https://example.com/docs/Too-Many-Statements.md",
        },
        // remaining URL schemes tests
        .{
            .input = "match ftp://example.com ftp links",
            .expect = "ftp://example.com",
        },
        .{
            .input = "match file://example.com file links",
            .expect = "file://example.com",
        },
        .{
            .input = "match ssh://example.com ssh links",
            .expect = "ssh://example.com",
        },
        .{
            .input = "match git://example.com git links",
            .expect = "git://example.com",
        },
        .{
            .input = "/tmp/test.txt http://www.google.com",
            .expect = "/tmp/test.txt",
        },
        .{
            .input = "match tel:+18005551234 tel links",
            .expect = "tel:+18005551234",
        },
        .{
            .input = "match magnet:?xt=urn:btih:1234567890 magnet links",
            .expect = "magnet:?xt=urn:btih:1234567890",
        },
        .{
            .input = "match ipfs://QmSomeHashValue ipfs links",
            .expect = "ipfs://QmSomeHashValue",
        },
        .{
            .input = "match ipns://QmSomeHashValue ipns links",
            .expect = "ipns://QmSomeHashValue",
        },
        .{
            .input = "match gemini://example.com gemini links",
            .expect = "gemini://example.com",
        },
        .{
            .input = "match gopher://example.com gopher links",
            .expect = "gopher://example.com",
        },
        .{
            .input = "match news:comp.infosystems.www.servers.unix news links",
            .expect = "news:comp.infosystems.www.servers.unix",
        },
        .{
            .input = "/Users/ghostty.user/code/example.py",
            .expect = "/Users/ghostty.user/code/example.py",
        },
        .{
            .input = "/Users/ghostty.user/code/../example.py",
            .expect = "/Users/ghostty.user/code/../example.py",
        },
        .{
            .input = "/Users/ghostty.user/code/../example.py hello world",
            .expect = "/Users/ghostty.user/code/../example.py",
        },
        .{
            .input = "../example.py",
            .expect = "../example.py",
        },
        .{
            .input = "../example.py ",
            .expect = "../example.py",
        },
        .{
            .input = "first time ../example.py contributor ",
            .expect = "../example.py",
        },
        .{
            .input = "[link](/home/user/ghostty.user/example)",
            .expect = "/home/user/ghostty.user/example",
        },
        // IPv6 URL tests - Basic tests
        .{
            .input = "Serving HTTP on :: port 8000 (http://[::]:8000/)",
            .expect = "http://[::]:8000/",
        },
        .{
            .input = "IPv6 address https://[2001:db8::1]:8080/path",
            .expect = "https://[2001:db8::1]:8080/path",
        },
        .{
            .input = "IPv6 localhost http://[::1]:3000",
            .expect = "http://[::1]:3000",
        },
        .{
            .input = "Complex IPv6 https://[2001:db8:85a3:8d3:1319:8a2e:370:7348]:443/",
            .expect = "https://[2001:db8:85a3:8d3:1319:8a2e:370:7348]:443/",
        },
        // IPv6 URL tests - URLs with paths and query parameters
        .{
            .input = "IPv6 with path https://[2001:db8::1]/path/to/resource",
            .expect = "https://[2001:db8::1]/path/to/resource",
        },
        .{
            .input = "IPv6 with query https://[2001:db8::1]:8080/api?param=value&other=123",
            .expect = "https://[2001:db8::1]:8080/api?param=value&other=123",
        },
        // IPv6 URL tests - Compressed forms
        .{
            .input = "IPv6 compressed http://[2001:db8::]:80/",
            .expect = "http://[2001:db8::]:80/",
        },
        .{
            .input = "IPv6 multiple zeros http://[2001:0:0:0:0:0:0:1]",
            .expect = "http://[2001:0:0:0:0:0:0:1]",
        },
        // IPv6 URL tests - Special cases
        .{
            .input = "IPv6 link-local https://[fe80::1234:5678:9abc]",
            .expect = "https://[fe80::1234:5678:9abc]",
        },
        .{
            .input = "IPv6 multicast http://[ff02::1]/stream",
            .expect = "http://[ff02::1]/stream",
        },
        // IPv6 URL tests - Mixed scenarios
        .{
            .input = "IPv6 in markdown [link](http://[2001:db8::1]/docs)",
            .expect = "http://[2001:db8::1]/docs",
        },
        // Trailing whitespace isn't part of a detected file path.
        .{
            .input = "./spaces-end.   ",
            .expect = "./spaces-end.",
        },
        // File paths with internal spaces
        .{
            .input = "./space middle",
            .expect = "./space middle",
        },
        .{
            .input = "../test folder/file.txt",
            .expect = "../test folder/file.txt",
        },
        .{
            .input = "/tmp/test folder/file.txt",
            .expect = "/tmp/test folder/file.txt",
        },
        .{
            .input = "/tmp/test  folder/file.txt",
            .expect = "/tmp/test",
        },
        // unified diff lines
        .{
            .input = "diff --git a/src/font/shaper/harfbuzz.zig b/src/font/shaper/harfbuzz.zig",
            .expect = "a/src/font/shaper/harfbuzz.zig",
        },
        // Two space-separated absolute paths should match only the first
        .{
            .input = "/tmp/foo /tmp/bar",
            .expect = "/tmp/foo",
        },
        .{
            .input = "/tmp/foo.txt /tmp/bar.txt",
            .expect = "/tmp/foo.txt",
        },
        // Bare relative file paths (no ./ or ../ prefix)
        .{
            .input = "src/config/url.zig",
            .expect = "src/config/url.zig",
        },
        .{
            .input = "app/folder/file.rb:1",
            .expect = "app/folder/file.rb:1",
        },
        .{
            .input = "modified:   src/config/url.zig",
            .expect = "src/config/url.zig",
        },
        .{
            .input = "lib/ghostty/terminal.zig:42:10",
            .expect = "lib/ghostty/terminal.zig:42:10",
        },
        .{
            .input = "some-pkg/src/file.txt more text",
            .expect = "some-pkg/src/file.txt",
        },
        // comma should match substrings
        .{
            .input = "src/foo.c,baz.txt",
            .expect = "src/foo.c",
        },
        .{
            .input = "~/foo/bar.txt",
            .expect = "~/foo/bar.txt",
        },
        .{
            .input = "open ~/Documents/notes.md please",
            .expect = "~/Documents/notes.md",
        },
        .{
            .input = "~/.config/ghostty/config",
            .expect = "~/.config/ghostty/config",
        },
        .{
            .input = "directory: ~/src/ghostty-org/ghostty",
            .expect = "~/src/ghostty-org/ghostty",
        },
        .{
            .input = "$HOME/src/config/url.zig",
            .expect = "$HOME/src/config/url.zig",
        },
        .{
            .input = "project dir: $PWD/src/ghostty/main.zig",
            .expect = "$PWD/src/ghostty/main.zig",
        },
        // $VAR mid-path should match fully, not partially from the $
        .{
            .input = "foo/$BAR/baz",
            .expect = "foo/$BAR/baz",
        },
        .{
            .input = ".foo/bar/$VAR",
            .expect = ".foo/bar/$VAR",
        },
        .{
            .input = ".config/ghostty/config",
            .expect = ".config/ghostty/config",
        },
        .{
            .input = "loaded from .local/share/ghostty/state.db now",
            .expect = ".local/share/ghostty/state.db",
        },
        .{
            .input = "../some/where",
            .expect = "../some/where",
        },
        // comma-separated file paths
        .{
            .input = "  - shared/src/foo/SomeItem.m:12, shared/src/",
            .expect = "shared/src/foo/SomeItem.m:12",
        },
        // mid-string dot should not partially match but fully
        .{
            .input = "foo.local/share",
            .expect = "foo.local/share",
        },
        // numeric directory should match fully
        .{
            .input = "2024/report.txt",
            .expect = "2024/report.txt",
        },
        // comma should stop matching in spaced path segments
        .{
            .input = "./foo bar,baz",
            .expect = "./foo bar",
        },
        .{
            .input = "/tmp/foo bar,baz",
            .expect = "/tmp/foo bar",
        },
        // trailing colon should not be part of the path
        .{
            .input = "./.config/ghostty: Needs upstream (main)",
            .expect = "./.config/ghostty",
        },
        .{
            .input = "./Downloads: Operation not permitted",
            .expect = "./Downloads",
        },
        // bare relative paths without any dot match here, but are only
        // links if they exist (see linkLen)
        .{
            .input = "input/output",
            .expect = "input/output",
        },
        .{
            .input = "cd src/config",
            .expect = "src/config",
        },
        // comma should not let dot detection look past it
        .{
            .input = "foo/bar,baz.txt",
            .expect = "foo/bar",
        },
        // directories take the words after them, which linkLen trims
        .{
            .input = "see ../blah/blah for details",
            .expect = "../blah/blah for details",
        },
        // grep -n output; linkLen trims the line number
        .{
            .input = "/Users/x/Repos/ghostty/build.zig:447:        .optimize = optimize,",
            .expect = "/Users/x/Repos/ghostty/build.zig:447",
        },
    };

    for (cases) |case| {
        //std.debug.print("input: {s}\n", .{case.input});
        //std.debug.print("match: {s}\n", .{case.expect});
        var reg = try re.search(case.input, .{});
        //std.debug.print("count: {d}\n", .{@as(usize, reg.count())});
        //std.debug.print("starts: {d}\n", .{reg.starts()});
        //std.debug.print("ends: {d}\n", .{reg.ends()});
        defer reg.deinit();
        try testing.expectEqual(@as(usize, case.num_matches), reg.count());
        const match = case.input[@intCast(reg.starts()[0])..@intCast(reg.ends()[0])];
        try testing.expectEqualStrings(case.expect, match);
    }

    const no_match_cases = [_][]const u8{
        // $-numeric character should not match
        "$10/bar",
        "$10/$20",
        "$10/bar.txt",
        // $VAR should not match mid-word
        "foo$BAR/baz.txt",
        // ~ should not match mid-word
        "foo~/bar.txt",
        // double-slash comments are not paths
        "// foo bar",
        "//foo",
    };
    for (no_match_cases) |input| {
        var result = re.search(input, .{});
        if (result) |*reg| {
            reg.deinit();
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

test "linkLen" {
    const testing = std.testing;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "Repos/ghostty");
    try tmp.dir.createDirPath(io, "blah/blah");
    try tmp.dir.createDirPath(io, "문서/보고서");
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/foo.zig", .data = "" });

    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    var repos_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const repos = try std.mem.print(&repos_buf, "{s}/Repos", .{root});

    // The tmp dir stands in for both the home directory and the pwd.
    const at_root: PathContext = .{ .pwd = root, .home = root };
    const at_repos: PathContext = .{ .pwd = repos, .home = root };
    const unknown: PathContext = .{};

    const Case = struct {
        ctx: PathContext,
        input: []const u8,
        expect: ?[]const u8,
    };
    const cases = [_]Case{
        // URLs are never checked
        .{ .ctx = at_root, .input = "https://example.com/a", .expect = "https://example.com/a" },
        .{ .ctx = at_root, .input = "mailto:test@example.com", .expect = "mailto:test@example.com" },

        // existing paths are kept whole
        .{ .ctx = at_root, .input = "~/Repos/ghostty", .expect = "~/Repos/ghostty" },
        .{ .ctx = at_root, .input = "blah/blah", .expect = "blah/blah" },
        .{ .ctx = at_repos, .input = "../blah/blah", .expect = "../blah/blah" },

        // trailing words and glued text are trimmed off
        .{ .ctx = at_root, .input = "~/Repos/ghostty에서 작업", .expect = "~/Repos/ghostty" },
        .{ .ctx = at_root, .input = "~/Repos/ghostty 에서", .expect = "~/Repos/ghostty" },
        .{ .ctx = at_root, .input = "~/Repos/ghostty.", .expect = "~/Repos/ghostty" },
        .{ .ctx = at_root, .input = "~/Repos/ghostty**", .expect = "~/Repos/ghostty" },
        .{ .ctx = at_root, .input = "~/Repos/ghostty/에서", .expect = "~/Repos/ghostty/" },
        .{ .ctx = at_repos, .input = "../blah/blah for details", .expect = "../blah/blah" },
        .{ .ctx = at_root, .input = "blah/blah를", .expect = "blah/blah" },
        .{ .ctx = at_root, .input = "blah/blah.", .expect = "blah/blah" },
        .{ .ctx = at_root, .input = "~/문서/보고서에서", .expect = "~/문서/보고서" },
        .{ .ctx = at_root, .input = "src/foo.zig에서", .expect = "src/foo.zig" },

        // line and column numbers are trimmed off
        .{ .ctx = at_root, .input = "src/foo.zig:42", .expect = "src/foo.zig" },
        .{ .ctx = at_root, .input = "src/foo.zig:42:10", .expect = "src/foo.zig" },
        .{ .ctx = at_root, .input = "src/foo.zig:42에서", .expect = "src/foo.zig" },
        .{ .ctx = at_root, .input = "~/src/foo.zig:42", .expect = "~/src/foo.zig" },
        .{ .ctx = at_root, .input = "blah/blah:42", .expect = "blah/blah" },
        .{ .ctx = at_root, .input = "/nonexistent/foo.zig:42", .expect = "/nonexistent/foo.zig:42" },

        // other letters and digits aren't trimmed
        .{ .ctx = at_root, .input = "src/foo.zig42", .expect = "src/foo.zig42" },
        .{ .ctx = at_root, .input = "~/Repos/ghost", .expect = "~/Repos/ghost" },

        // paths that don't exist or can't be checked are kept whole
        .{ .ctx = at_root, .input = "/nonexistent/thing for details", .expect = "/nonexistent/thing for details" },
        .{ .ctx = at_root, .input = "~/에서", .expect = "~/에서" },
        .{ .ctx = at_root, .input = "$HOME/Repos/ghostty에서", .expect = "$HOME/Repos/ghostty에서" },
        .{ .ctx = unknown, .input = "~/Repos/ghostty에서", .expect = "~/Repos/ghostty에서" },
        .{ .ctx = unknown, .input = "../blah/blah for details", .expect = "../blah/blah for details" },

        // ...except bare paths without a dot, which must exist
        .{ .ctx = at_root, .input = "input/output", .expect = null },
        .{ .ctx = at_root, .input = "foo/bar", .expect = null },
        .{ .ctx = at_root, .input = "input/output.", .expect = null },
        .{ .ctx = at_repos, .input = "blah/blah", .expect = null },
        .{ .ctx = unknown, .input = "blah/blah", .expect = null },
    };

    for (cases) |case| {
        const len = linkLen(io, case.input, case.ctx);
        if (case.expect) |expect| {
            const actual = case.input[0 .. len orelse {
                std.debug.print("input: {s} expected: {s} got: null\n", .{ case.input, expect });
                return error.TestUnexpectedResult;
            }];
            testing.expectEqualStrings(expect, actual) catch |err| {
                std.debug.print("input: {s}\n", .{case.input});
                return err;
            };
        } else {
            testing.expectEqual(@as(?usize, null), len) catch |err| {
                std.debug.print("input: {s}\n", .{case.input});
                return err;
            };
        }
    }
}
