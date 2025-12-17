//! Pattern Matcher
//!
//! Matches paths against compiled gitignore patterns.
//! Uses segment-based matching for efficiency.

const std = @import("std");
const pattern = @import("pattern.zig");

const Pattern = pattern.Pattern;
const Segment = pattern.Segment;
const Element = pattern.Element;
const CharClass = pattern.CharClass;

/// Options for matching behavior
pub const MatchOptions = struct {
    /// Case-insensitive matching
    ignore_case: bool = true,
};

/// Match a pattern against a path
/// Returns true if the pattern matches the path
pub fn matchPattern(pat: Pattern, path: []const u8, is_dir: bool, options: MatchOptions) bool {
    // Check directory-only constraint
    // Directory-only patterns require the path to be a directory
    if (pat.flags.dir_only and !is_dir and !std.mem.endsWith(u8, path, "/")) {
        return false;
    }

    // Normalize path: remove trailing slash for matching
    var normalized_path = path;
    if (normalized_path.len > 0 and normalized_path[normalized_path.len - 1] == '/') {
        normalized_path = normalized_path[0 .. normalized_path.len - 1];
    }

    // Split path into segments
    var path_segments: [128][]const u8 = undefined;
    var path_seg_count: usize = 0;

    var it = std.mem.splitScalar(u8, normalized_path, '/');
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        if (path_seg_count >= path_segments.len) return false; // Path too deep
        path_segments[path_seg_count] = seg;
        path_seg_count += 1;
    }

    const path_segs = path_segments[0..path_seg_count];

    if (pat.flags.anchored) {
        // Anchored pattern: must match from the beginning
        return matchSegments(pat.segments, path_segs, 0, 0, options);
    } else {
        // Non-anchored: can match at any level
        var start: usize = 0;
        while (start <= path_seg_count) : (start += 1) {
            if (matchSegments(pat.segments, path_segs, 0, start, options)) {
                return true;
            }
        }
        return false;
    }
}

/// Match pattern segments against path segments
fn matchSegments(
    pat_segs: []const Segment,
    path_segs: []const []const u8,
    pat_idx: usize,
    path_idx: usize,
    options: MatchOptions,
) bool {
    // Base cases
    if (pat_idx >= pat_segs.len) {
        // Pattern exhausted - match if path also exhausted
        return path_idx >= path_segs.len;
    }

    if (path_idx >= path_segs.len) {
        // Path exhausted - check remaining pattern segments
        const remaining = pat_segs[pat_idx..];

        // Special case: a single trailing globstar (like in abc/**) should NOT
        // match when path is exhausted, because it means "content inside",
        // not the directory itself.
        if (remaining.len == 1 and remaining[0].is_globstar) {
            return false;
        }

        // For other cases, match only if remaining patterns are all globstars
        // (e.g., **/foo/** matching foo - the leading ** can match 0 segments)
        for (remaining) |seg| {
            if (!seg.is_globstar) return false;
        }
        return true;
    }

    const pat_seg = pat_segs[pat_idx];

    if (pat_seg.is_globstar) {
        // Check if this is a trailing globstar (last segment in pattern)
        const is_trailing = pat_idx == pat_segs.len - 1;

        // Globstar: try matching zero or more segments
        // Non-trailing globstar can skip (match 0 segments)
        if (!is_trailing) {
            if (matchSegments(pat_segs, path_segs, pat_idx + 1, path_idx, options)) {
                return true;
            }
        }

        // For trailing globstar: if there's at least one path segment to consume,
        // that's a successful match (the globstar matches the remaining path)
        if (is_trailing) {
            // Trailing globstar with remaining path segments = match!
            // The globstar consumes everything remaining
            return true;
        }

        // For non-trailing globstar: try consuming one segment and recurse
        return matchSegments(pat_segs, path_segs, pat_idx, path_idx + 1, options);
    }

    // Normal segment: must match current path segment
    if (!matchSegment(pat_seg, path_segs[path_idx], options)) {
        return false;
    }

    // Continue with next segments
    return matchSegments(pat_segs, path_segs, pat_idx + 1, path_idx + 1, options);
}

/// Match a single segment against a path component
fn matchSegment(seg: Segment, text: []const u8, options: MatchOptions) bool {
    return matchElements(seg.elements, text, 0, 0, options);
}

/// Match elements against text using recursive backtracking
fn matchElements(
    elements: []const Element,
    text: []const u8,
    elem_idx: usize,
    text_idx: usize,
    options: MatchOptions,
) bool {
    // Base cases
    if (elem_idx >= elements.len) {
        return text_idx >= text.len;
    }

    const elem = elements[elem_idx];

    switch (elem) {
        .literal => |lit| {
            // Must match literal exactly
            if (text_idx + lit.len > text.len) return false;

            const slice = text[text_idx .. text_idx + lit.len];
            const matches = if (options.ignore_case)
                std.ascii.eqlIgnoreCase(slice, lit)
            else
                std.mem.eql(u8, slice, lit);

            if (!matches) return false;
            return matchElements(elements, text, elem_idx + 1, text_idx + lit.len, options);
        },

        .single_char => {
            // Match any single character (not /)
            if (text_idx >= text.len) return false;
            if (text[text_idx] == '/') return false;
            return matchElements(elements, text, elem_idx + 1, text_idx + 1, options);
        },

        .star => {
            // Match zero or more characters (not /)
            // Try matching 0 characters first, then more
            var try_len: usize = 0;
            while (text_idx + try_len <= text.len) {
                // Don't cross a /
                if (try_len > 0 and text[text_idx + try_len - 1] == '/') {
                    break;
                }

                if (matchElements(elements, text, elem_idx + 1, text_idx + try_len, options)) {
                    return true;
                }

                if (text_idx + try_len >= text.len) break;
                if (text[text_idx + try_len] == '/') break;

                try_len += 1;
            }
            return false;
        },

        .char_class => |class| {
            if (text_idx >= text.len) return false;

            const char = text[text_idx];
            if (options.ignore_case) {
                // For case-insensitive matching, check both cases
                const lower = std.ascii.toLower(char);
                const upper = std.ascii.toUpper(char);

                // For non-negated classes: match if either case matches
                // For negated classes: match only if NEITHER case is in the class
                if (class.negated) {
                    // Negated: both cases must NOT be in the class
                    if (!class.matchesWithoutNegation(lower) and !class.matchesWithoutNegation(upper)) {
                        return matchElements(elements, text, elem_idx + 1, text_idx + 1, options);
                    }
                    return false;
                } else {
                    // Non-negated: either case can match
                    if (class.matchesWithoutNegation(lower) or class.matchesWithoutNegation(upper)) {
                        return matchElements(elements, text, elem_idx + 1, text_idx + 1, options);
                    }
                    return false;
                }
            } else {
                if (!class.matches(char)) return false;
                return matchElements(elements, text, elem_idx + 1, text_idx + 1, options);
            }
        },
    }
}

/// Check if a path is valid for matching
/// Rejects absolute paths and relative paths like ./foo or ../foo
pub fn isValidPath(path: []const u8) bool {
    if (path.len == 0) return false;

    // Reject absolute paths
    if (path[0] == '/') return false;

    // Reject Windows absolute paths
    if (path.len >= 2 and path[1] == ':') return false;

    // Reject . and ..
    if (std.mem.eql(u8, path, ".") or std.mem.eql(u8, path, "..")) {
        return false;
    }

    // Reject paths starting with ./ or ../
    if (std.mem.startsWith(u8, path, "./") or std.mem.startsWith(u8, path, "../")) {
        return false;
    }

    return true;
}

// =============================================================================
// Tests
// =============================================================================

test "isValidPath" {
    try std.testing.expect(isValidPath("foo"));
    try std.testing.expect(isValidPath("foo/bar"));
    try std.testing.expect(isValidPath(".gitignore"));
    try std.testing.expect(isValidPath("a/b/c.txt"));

    try std.testing.expect(!isValidPath(""));
    try std.testing.expect(!isValidPath("/foo"));
    try std.testing.expect(!isValidPath("."));
    try std.testing.expect(!isValidPath(".."));
    try std.testing.expect(!isValidPath("./foo"));
    try std.testing.expect(!isValidPath("../foo"));
    try std.testing.expect(!isValidPath("C:/foo"));
}

test "matchElements literal" {
    const elements = [_]Element{.{ .literal = "foo" }};
    const opts = MatchOptions{};

    try std.testing.expect(matchElements(&elements, "foo", 0, 0, opts));
    try std.testing.expect(!matchElements(&elements, "bar", 0, 0, opts));
    try std.testing.expect(!matchElements(&elements, "foobar", 0, 0, opts));
    try std.testing.expect(!matchElements(&elements, "fo", 0, 0, opts));
}

test "matchElements literal case insensitive" {
    const elements = [_]Element{.{ .literal = "foo" }};
    const opts = MatchOptions{ .ignore_case = true };

    try std.testing.expect(matchElements(&elements, "foo", 0, 0, opts));
    try std.testing.expect(matchElements(&elements, "FOO", 0, 0, opts));
    try std.testing.expect(matchElements(&elements, "Foo", 0, 0, opts));
}

test "matchElements star" {
    const elements = [_]Element{ .star, .{ .literal = ".js" } };
    const opts = MatchOptions{};

    try std.testing.expect(matchElements(&elements, "foo.js", 0, 0, opts));
    try std.testing.expect(matchElements(&elements, ".js", 0, 0, opts));
    try std.testing.expect(matchElements(&elements, "bar.js", 0, 0, opts));
    try std.testing.expect(!matchElements(&elements, "foo.ts", 0, 0, opts));
}

test "matchElements single_char" {
    const elements = [_]Element{ .{ .literal = "a" }, .single_char, .{ .literal = "c" } };
    const opts = MatchOptions{};

    try std.testing.expect(matchElements(&elements, "abc", 0, 0, opts));
    try std.testing.expect(matchElements(&elements, "axc", 0, 0, opts));
    try std.testing.expect(!matchElements(&elements, "ac", 0, 0, opts));
    try std.testing.expect(!matchElements(&elements, "abbc", 0, 0, opts));
}

test "matchElements char_class basic" {
    const class = CharClass{
        .chars = "abc",
        .ranges = &[_]CharClass.Range{},
        .negated = false,
    };
    const elements = [_]Element{.{ .char_class = class }};
    const opts = MatchOptions{ .ignore_case = false };

    try std.testing.expect(matchElements(&elements, "a", 0, 0, opts));
    try std.testing.expect(matchElements(&elements, "b", 0, 0, opts));
    try std.testing.expect(matchElements(&elements, "c", 0, 0, opts));
    try std.testing.expect(!matchElements(&elements, "d", 0, 0, opts));
}

test "matchElements char_class range" {
    const class = CharClass{
        .chars = "",
        .ranges = &[_]CharClass.Range{.{ .start = 'a', .end = 'z' }},
        .negated = false,
    };
    const elements = [_]Element{.{ .char_class = class }};
    const opts = MatchOptions{ .ignore_case = false };

    try std.testing.expect(matchElements(&elements, "a", 0, 0, opts));
    try std.testing.expect(matchElements(&elements, "m", 0, 0, opts));
    try std.testing.expect(matchElements(&elements, "z", 0, 0, opts));
    try std.testing.expect(!matchElements(&elements, "A", 0, 0, opts));
    try std.testing.expect(!matchElements(&elements, "0", 0, 0, opts));
}

test "matchSegment with star" {
    const seg = Segment{
        .elements = &[_]Element{ .star, .{ .literal = ".log" } },
        .is_globstar = false,
    };
    const opts = MatchOptions{};

    try std.testing.expect(matchSegment(seg, "test.log", opts));
    try std.testing.expect(matchSegment(seg, ".log", opts));
    try std.testing.expect(matchSegment(seg, "foo.log", opts));
    try std.testing.expect(!matchSegment(seg, "test.txt", opts));
}
