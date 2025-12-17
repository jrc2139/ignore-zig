//! Comprehensive test cases ported from node-ignore
//!
//! These tests ensure compatibility with node-ignore's behavior.

const std = @import("std");
const Ignore = @import("ignore.zig").Ignore;

// Helper to run test cases
fn testCase(patterns: []const []const u8, expectations: []const struct { path: []const u8, ignored: bool }) !void {
    var ig = Ignore.init(std.testing.allocator, .{});
    defer ig.deinit();

    for (patterns) |pattern| {
        try ig.addPattern(pattern);
    }

    for (expectations) |exp| {
        const result = ig.ignores(exp.path);
        if (result != exp.ignored) {
            std.debug.print("\nFailed: path '{s}'\n  Expected ignored={}, got ignored={}\n  Patterns: ", .{ exp.path, exp.ignored, result });
            for (patterns) |p| {
                std.debug.print("'{s}' ", .{p});
            }
            std.debug.print("\n", .{});
            return error.TestFailed;
        }
    }
}

// =============================================================================
// Wildcard Tests
// =============================================================================

test "basic wildcard *" {
    try testCase(&.{"*.log"}, &.{
        .{ .path = "test.log", .ignored = true },
        .{ .path = "debug.log", .ignored = true },
        .{ .path = "test.txt", .ignored = false },
        .{ .path = "dir/test.log", .ignored = true },
    });
}

test "wildcard in middle" {
    try testCase(&.{"foo*bar"}, &.{
        .{ .path = "foobar", .ignored = true },
        .{ .path = "fooxbar", .ignored = true },
        .{ .path = "fooxyzbar", .ignored = true },
        .{ .path = "foo/bar", .ignored = false }, // * doesn't match /
    });
}

test "question mark ?" {
    try testCase(&.{"foo?bar"}, &.{
        .{ .path = "fooxbar", .ignored = true },
        .{ .path = "foo/bar", .ignored = false }, // ? doesn't match /
        .{ .path = "fooxxbar", .ignored = false },
    });
}

test "intermediate question mark" {
    try testCase(&.{"a?c"}, &.{
        .{ .path = "abc", .ignored = true },
        .{ .path = "acc", .ignored = true },
        .{ .path = "ac", .ignored = false },
        .{ .path = "abbc", .ignored = false },
    });
}

test "multiple question marks" {
    try testCase(&.{"a?b??"}, &.{
        .{ .path = "acbdd", .ignored = true },
        .{ .path = "acbddd", .ignored = false },
    });
}

// =============================================================================
// Globstar Tests
// =============================================================================

test "leading **" {
    try testCase(&.{"**/foo"}, &.{
        .{ .path = "foo", .ignored = true },
        .{ .path = "a/foo", .ignored = true },
        .{ .path = "a/b/foo", .ignored = true },
        .{ .path = "a/b/c/foo", .ignored = true },
    });
}

test "trailing **" {
    try testCase(&.{"abc/**"}, &.{
        .{ .path = "abc/a", .ignored = true },
        .{ .path = "abc/b", .ignored = true },
        .{ .path = "abc/d/e/f", .ignored = true },
        .{ .path = "abc", .ignored = false },
        .{ .path = "bcd/abc/a", .ignored = false },
    });
}

test "middle **" {
    try testCase(&.{"a/**/b"}, &.{
        .{ .path = "a/b", .ignored = true },
        .{ .path = "a/x/b", .ignored = true },
        .{ .path = "a/x/y/b", .ignored = true },
        .{ .path = "b/a/b", .ignored = false },
    });
}

test "**/foo/bar matches anywhere" {
    try testCase(&.{"**/foo/bar"}, &.{
        .{ .path = "foo/bar", .ignored = true },
        .{ .path = "abc/foo/bar", .ignored = true },
        .{ .path = "abc/foo/bar/", .ignored = true },
    });
}

// =============================================================================
// Character Class Tests
// =============================================================================

test "character class [abc]" {
    try testCase(&.{"[abc].txt"}, &.{
        .{ .path = "a.txt", .ignored = true },
        .{ .path = "b.txt", .ignored = true },
        .{ .path = "c.txt", .ignored = true },
        .{ .path = "d.txt", .ignored = false },
    });
}

test "character class *.[oa]" {
    try testCase(&.{"*.[oa]"}, &.{
        .{ .path = "a.o", .ignored = true },
        .{ .path = "a.a", .ignored = true },
        .{ .path = "a.js", .ignored = false },
        .{ .path = "a.aa", .ignored = false },
    });
}

test "character range [a-z]" {
    try testCase(&.{"*.pn[a-z]"}, &.{
        .{ .path = "a.png", .ignored = true },
        .{ .path = "a.pna", .ignored = true },
        .{ .path = "a.pn1", .ignored = false },
        .{ .path = "a.pn2", .ignored = false },
    });
}

test "character range [0-9]" {
    try testCase(&.{"*.pn[0-9]"}, &.{
        .{ .path = "a.pn1", .ignored = true },
        .{ .path = "a.pn2", .ignored = true },
        .{ .path = "a.png", .ignored = false },
        .{ .path = "a.pna", .ignored = false },
    });
}

test "multiple ranges [0-9a-z]" {
    try testCase(&.{"*.pn[0-9a-z]"}, &.{
        .{ .path = "a.pn1", .ignored = true },
        .{ .path = "a.pn2", .ignored = true },
        .{ .path = "a.png", .ignored = true },
        .{ .path = "a.pna", .ignored = true },
        .{ .path = "a.pn-", .ignored = false },
    });
}

test "invalid range [z-a] ignored" {
    try testCase(&.{"*.[z-a]"}, &.{
        .{ .path = "a.0", .ignored = false },
        .{ .path = "a.-", .ignored = false },
        .{ .path = "a.9", .ignored = false },
    });
}

test "negated character class [!abc]" {
    try testCase(&.{"[!abc].txt"}, &.{
        .{ .path = "a.txt", .ignored = false },
        .{ .path = "b.txt", .ignored = false },
        .{ .path = "c.txt", .ignored = false },
        .{ .path = "d.txt", .ignored = true },
        .{ .path = "x.txt", .ignored = true },
    });
}

// =============================================================================
// Negation Tests
// =============================================================================

test "basic negation" {
    try testCase(&.{ "*.log", "!important.log" }, &.{
        .{ .path = "debug.log", .ignored = true },
        .{ .path = "important.log", .ignored = false },
    });
}

test "negation order matters - unignore then ignore" {
    try testCase(&.{ "!foo/bar.js", "foo/*" }, &.{
        .{ .path = "foo/bar.js", .ignored = true },
        .{ .path = "foo/bar2.js", .ignored = true },
    });
}

test "negation order matters - ignore then unignore" {
    try testCase(&.{ "foo/*", "!foo/bar.js" }, &.{
        .{ .path = "foo/bar.js", .ignored = false },
        .{ .path = "foo/bar2.js", .ignored = true },
    });
}

test "re-ignore after negation" {
    try testCase(&.{ "*.txt", "!important.txt", "*.txt" }, &.{
        .{ .path = "important.txt", .ignored = true },
    });
}

test "#26: .gitignore man page example" {
    try testCase(&.{ "/*", "!/foo", "/foo/*", "!/foo/bar" }, &.{
        .{ .path = "no.js", .ignored = true },
        .{ .path = "foo/no.js", .ignored = true },
        .{ .path = "foo/bar/yes.js", .ignored = false },
        .{ .path = "foo/bar/baz/yes.js", .ignored = false },
        .{ .path = "boo/no.js", .ignored = true },
    });
}

// =============================================================================
// Parent Directory Exclusion Tests
// =============================================================================

test "#10: parent directory excluded prevents re-inclusion" {
    try testCase(&.{ "/abc/", "!/abc/a.js" }, &.{
        .{ .path = "abc/a.js", .ignored = true }, // Can't un-ignore
        .{ .path = "abc/d/e.js", .ignored = true },
    });
}

test "parent directory excluded - file pattern" {
    try testCase(&.{ "abc", "!bcd/abc/a.js" }, &.{
        .{ .path = "abc/a.js", .ignored = true },
        .{ .path = "bcd/abc/a.js", .ignored = true }, // abc dir is ignored
    });
}

test "#14: README example" {
    try testCase(&.{ ".abc/*", "!.abc/d/" }, &.{
        .{ .path = ".abc/a.js", .ignored = true },
        .{ .path = ".abc/d/e.js", .ignored = false },
    });
}

// =============================================================================
// Directory Pattern Tests
// =============================================================================

test "directory only pattern" {
    var ig = Ignore.init(std.testing.allocator, .{});
    defer ig.deinit();

    try ig.addPattern("build/");

    // With explicit directory flag
    try std.testing.expect(ig.ignoresEx("build", true));
    try std.testing.expect(!ig.ignoresEx("build", false)); // file named build

    // With trailing slash in path
    try std.testing.expect(ig.ignores("build/"));
}

test "trailing / matches at any level" {
    try testCase(&.{"abc/"}, &.{
        .{ .path = "abc/", .ignored = true },
        .{ .path = "bcd/abc/", .ignored = true },
        .{ .path = "abc", .ignored = false },
    });
}

test "node_modules at any level" {
    try testCase(&.{"node_modules/"}, &.{
        .{ .path = "node_modules/gulp/node_modules/abc.md", .ignored = true },
        .{ .path = "a/b/node_modules/abc.md", .ignored = true },
    });
}

// =============================================================================
// Anchoring Tests
// =============================================================================

test "leading / anchors to root" {
    try testCase(&.{"/*.c"}, &.{
        .{ .path = "cat-file.c", .ignored = true },
        .{ .path = "mozilla-sha1/sha1.c", .ignored = false },
    });
}

test "internal / anchors pattern" {
    try testCase(&.{"a/a.js"}, &.{
        .{ .path = "a/a.js", .ignored = true },
        .{ .path = "a/a.jsa", .ignored = false },
        .{ .path = "b/a/a.js", .ignored = false },
        .{ .path = "c/a/a.js", .ignored = false },
    });
}

test "no slash - matches at any level" {
    try testCase(&.{"a.js"}, &.{
        .{ .path = "a.js", .ignored = true },
        .{ .path = "b/a/a.js", .ignored = true },
        .{ .path = "a/a.js", .ignored = true },
    });
}

// =============================================================================
// Escape Tests
// =============================================================================

test "escaped hash" {
    try testCase(&.{"\\#abc"}, &.{
        .{ .path = "#abc", .ignored = true },
    });
}

test "escaped exclamation" {
    try testCase(&.{ "\\!abc", "\\!important!.txt" }, &.{
        .{ .path = "!abc", .ignored = true },
        .{ .path = "abc", .ignored = false },
        .{ .path = "!important!.txt", .ignored = true },
        .{ .path = "b/!important!.txt", .ignored = true },
    });
}

test "escaped wildcard" {
    try testCase(&.{ "*.html", "!a/b/\\*/index.html" }, &.{
        .{ .path = "a/b/*/index.html", .ignored = false },
        .{ .path = "a/b/index.html", .ignored = true },
    });
}

// =============================================================================
// Comment and Empty Line Tests
// =============================================================================

test "comments are ignored" {
    try testCase(&.{ "# comment", "*.log", "# another comment" }, &.{
        .{ .path = "test.log", .ignored = true },
        .{ .path = "#abc", .ignored = false },
    });
}

test "empty lines are ignored" {
    try testCase(&.{ "", "*.log", "" }, &.{
        .{ .path = "test.log", .ignored = true },
    });
}

test "comment without space is pattern" {
    // "node_modules# comments" is NOT a comment
    try testCase(&.{"node_modules# comments"}, &.{
        .{ .path = "node_modules/a.js", .ignored = false },
    });
}

// =============================================================================
// Trailing Space Tests
// =============================================================================

test "trailing spaces stripped" {
    try testCase(&.{ "bcd  ", "def " }, &.{
        .{ .path = "bcd", .ignored = true },
        .{ .path = "bcd ", .ignored = false },
        .{ .path = "def", .ignored = true },
        .{ .path = "def ", .ignored = false },
    });
}

// =============================================================================
// Dot File Tests
// =============================================================================

test "dot files" {
    try testCase(&.{".*"}, &.{
        .{ .path = ".a", .ignored = true },
        .{ .path = ".gitignore", .ignored = true },
    });
}

test "dot file specific" {
    try testCase(&.{".d"}, &.{
        .{ .path = ".d", .ignored = true },
        .{ .path = ".dd", .ignored = false },
        .{ .path = "d.d", .ignored = false },
        .{ .path = "d/.d", .ignored = true },
    });
}

// =============================================================================
// Complex Patterns
// =============================================================================

test "#25: .git config" {
    try testCase(&.{ ".git/*", "!.git/config", ".ftpconfig" }, &.{
        .{ .path = ".ftpconfig", .ignored = true },
        .{ .path = ".git/config", .ignored = false },
        .{ .path = ".git/description", .ignored = true },
    });
}

test "#38: dir negation" {
    try testCase(&.{ "*", "!*/", "!foo/bar" }, &.{
        .{ .path = "a", .ignored = true },
        .{ .path = "b/c", .ignored = true },
        .{ .path = "foo/bar", .ignored = false },
        .{ .path = "foo/e", .ignored = true },
    });
}

test "abc* negation" {
    try testCase(&.{ "*", "!abc*" }, &.{
        .{ .path = "a", .ignored = true },
        .{ .path = "abc", .ignored = false },
        .{ .path = "abcd", .ignored = false },
    });
}

// =============================================================================
// Special Cases
// =============================================================================

test "file ending with *" {
    try testCase(&.{"abc.js*"}, &.{
        .{ .path = "abc.js/", .ignored = true },
        .{ .path = "abc.js/abc", .ignored = true },
        .{ .path = "abc.jsa/", .ignored = true },
        .{ .path = "abc.jsa/abc", .ignored = true },
    });
}

test "dir ending with *" {
    try testCase(&.{"abc/*"}, &.{
        .{ .path = "abc", .ignored = false },
    });
}

test "wildcard as filename *.b" {
    try testCase(&.{"*.b"}, &.{
        .{ .path = "b/a.b", .ignored = true },
        .{ .path = "b/.b", .ignored = true },
        .{ .path = "b/.ba", .ignored = false },
        .{ .path = "b/c/a.b", .ignored = true },
    });
}
