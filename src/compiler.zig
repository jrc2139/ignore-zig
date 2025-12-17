//! Pattern Compiler
//!
//! Compiles gitignore pattern strings into structured Pattern objects.
//! Handles all gitignore edge cases:
//! - BOM removal
//! - Comments (#)
//! - Negation (!)
//! - Directory-only patterns (trailing /)
//! - Anchoring (leading / or internal /)
//! - Escaped characters (\*, \ , \!, \#)
//! - Character classes ([abc], [a-z], [!abc])
//! - Wildcards (*, **, ?)
//! - Trailing space handling

const std = @import("std");
const pattern = @import("pattern.zig");

const Pattern = pattern.Pattern;
const PatternFlags = pattern.PatternFlags;
const Segment = pattern.Segment;
const Element = pattern.Element;
const CharClass = pattern.CharClass;

/// Compiler for gitignore patterns
pub const Compiler = struct {
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator) Compiler {
        return .{
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *Compiler) void {
        self.arena.deinit();
    }

    /// Compile a gitignore pattern line
    /// Returns null if the pattern should be skipped (empty, comment, invalid)
    pub fn compile(self: *Compiler, raw_line: []const u8) ?Pattern {
        const alloc = self.arena.allocator();
        var line = raw_line;

        // Step 1: Remove UTF-8 BOM if present
        if (line.len >= 3 and std.mem.eql(u8, line[0..3], "\xEF\xBB\xBF")) {
            line = line[3..];
        }

        // Step 2: Trim leading/trailing whitespace for initial check
        const trimmed = std.mem.trim(u8, line, " \t\r");

        // Step 3: Skip empty lines
        if (trimmed.len == 0) return null;

        // Step 4: Skip comments (lines starting with #)
        if (trimmed[0] == '#') return null;

        // Step 5: Check for invalid trailing backslash
        if (hasInvalidTrailingBackslash(trimmed)) return null;

        // Step 6: Process trailing spaces (escaped vs unescaped)
        line = processTrailingSpaces(trimmed);
        if (line.len == 0) return null;

        // Step 7: Parse flags and clean the pattern
        var flags = PatternFlags{};
        var pattern_body = line;

        // Check for negation prefix
        if (pattern_body.len > 0 and pattern_body[0] == '!') {
            flags.negated = true;
            pattern_body = pattern_body[1..];
        } else if (pattern_body.len > 1 and pattern_body[0] == '\\' and pattern_body[1] == '!') {
            // Escaped ! at start - literal exclamation
            pattern_body = pattern_body[1..];
        }

        // Check for escaped # at start
        if (pattern_body.len > 1 and pattern_body[0] == '\\' and pattern_body[1] == '#') {
            pattern_body = pattern_body[1..];
        }

        // Check for directory-only (trailing /)
        if (pattern_body.len > 0 and pattern_body[pattern_body.len - 1] == '/') {
            flags.dir_only = true;
            pattern_body = pattern_body[0 .. pattern_body.len - 1];
        }

        // Check for anchoring (leading /)
        if (pattern_body.len > 0 and pattern_body[0] == '/') {
            flags.anchored = true;
            pattern_body = pattern_body[1..];
        }

        // Skip empty patterns after processing
        if (pattern_body.len == 0) return null;

        // Check for internal slash (also anchors the pattern)
        // But not if it starts with ** (globstar at start is special)
        if (!flags.anchored and !std.mem.startsWith(u8, pattern_body, "**")) {
            if (std.mem.indexOfScalar(u8, pattern_body, '/')) |_| {
                flags.anchored = true;
            }
        }

        // Step 8: Parse segments
        const segments = self.parseSegments(alloc, pattern_body) catch return null;

        // Store original for debugging
        const original = alloc.dupe(u8, raw_line) catch return null;

        return Pattern{
            .original = original,
            .segments = segments,
            .flags = flags,
        };
    }

    /// Parse pattern body into segments (split by /)
    fn parseSegments(self: *Compiler, alloc: std.mem.Allocator, body: []const u8) ![]const Segment {
        _ = self;
        var segments = std.ArrayListUnmanaged(Segment){};

        var it = std.mem.splitScalar(u8, body, '/');
        while (it.next()) |part| {
            // Skip empty parts (from leading/trailing/consecutive slashes)
            if (part.len == 0) continue;

            // Check for globstar
            if (std.mem.eql(u8, part, "**")) {
                try segments.append(alloc, .{
                    .elements = &[_]Element{},
                    .is_globstar = true,
                });
            } else {
                const elements = try parseElements(alloc, part);
                try segments.append(alloc, .{
                    .elements = elements,
                    .is_globstar = false,
                });
            }
        }

        return segments.toOwnedSlice(alloc);
    }
};

/// Check if a line has an invalid trailing backslash
/// A trailing backslash is invalid if there's an odd number of backslashes at the end
fn hasInvalidTrailingBackslash(line: []const u8) bool {
    if (line.len == 0) return false;

    var count: usize = 0;
    var i = line.len;
    while (i > 0) {
        i -= 1;
        if (line[i] == '\\') {
            count += 1;
        } else {
            break;
        }
    }

    // Odd number of trailing backslashes is invalid
    return count % 2 == 1;
}

/// Process trailing spaces according to gitignore rules
/// - "abc\\ " -> "abc " (escaped space preserved)
/// - "abc  "  -> "abc"  (unescaped spaces stripped)
fn processTrailingSpaces(line: []const u8) []const u8 {
    if (line.len == 0) return line;

    var end = line.len;

    // Work backwards from the end
    while (end > 0) {
        const c = line[end - 1];

        if (c != ' ' and c != '\t') {
            break;
        }

        // Found whitespace - check if it's escaped
        if (end >= 2 and line[end - 2] == '\\') {
            // Count preceding backslashes
            var backslash_count: usize = 0;
            var j = end - 2;
            while (j > 0 and line[j - 1] == '\\') {
                backslash_count += 1;
                j -= 1;
            }
            backslash_count += 1; // Include the one at end-2

            if (backslash_count % 2 == 1) {
                // Odd backslashes - space is escaped, stop here
                break;
            }
        }

        // Unescaped trailing whitespace - remove it
        end -= 1;
    }

    return line[0..end];
}

/// Parse a segment into elements
fn parseElements(alloc: std.mem.Allocator, segment: []const u8) ![]const Element {
    var elements = std.ArrayListUnmanaged(Element){};
    var literal_buf = std.ArrayListUnmanaged(u8){};

    var i: usize = 0;
    while (i < segment.len) {
        const c = segment[i];

        switch (c) {
            '\\' => {
                // Escape sequence
                if (i + 1 < segment.len) {
                    // Add escaped character to literal buffer
                    try literal_buf.append(alloc, segment[i + 1]);
                    i += 2;
                } else {
                    // Trailing backslash - shouldn't happen if hasInvalidTrailingBackslash works
                    try literal_buf.append(alloc, '\\');
                    i += 1;
                }
            },
            '*' => {
                // Flush literal buffer
                if (literal_buf.items.len > 0) {
                    const lit = try literal_buf.toOwnedSlice(alloc);
                    try elements.append(alloc, .{ .literal = lit });
                }

                // Consume consecutive *s (treat ** within segment as single *)
                while (i + 1 < segment.len and segment[i + 1] == '*') {
                    i += 1;
                }
                try elements.append(alloc, .star);
                i += 1;
            },
            '?' => {
                // Flush literal buffer
                if (literal_buf.items.len > 0) {
                    const lit = try literal_buf.toOwnedSlice(alloc);
                    try elements.append(alloc, .{ .literal = lit });
                }
                try elements.append(alloc, .single_char);
                i += 1;
            },
            '[' => {
                // Flush literal buffer
                if (literal_buf.items.len > 0) {
                    const lit = try literal_buf.toOwnedSlice(alloc);
                    try elements.append(alloc, .{ .literal = lit });
                }

                // Try to parse character class
                if (parseCharClass(alloc, segment[i..])) |result| {
                    try elements.append(alloc, .{ .char_class = result.class });
                    i += result.consumed;
                } else |_| {
                    // Invalid character class - treat [ as literal
                    try literal_buf.append(alloc, '[');
                    i += 1;
                }
            },
            else => {
                try literal_buf.append(alloc, c);
                i += 1;
            },
        }
    }

    // Flush remaining literal buffer
    if (literal_buf.items.len > 0) {
        const lit = try literal_buf.toOwnedSlice(alloc);
        try elements.append(alloc, .{ .literal = lit });
    }

    return elements.toOwnedSlice(alloc);
}

const CharClassResult = struct {
    class: CharClass,
    consumed: usize,
};

/// Parse a character class like [abc], [a-z], [!abc]
fn parseCharClass(alloc: std.mem.Allocator, input: []const u8) !CharClassResult {
    if (input.len < 2 or input[0] != '[') {
        return error.InvalidPattern;
    }

    var i: usize = 1;
    var negated = false;

    // Check for negation
    if (i < input.len and (input[i] == '!' or input[i] == '^')) {
        negated = true;
        i += 1;
    }

    var chars = std.ArrayListUnmanaged(u8){};
    errdefer chars.deinit(alloc);
    var ranges = std.ArrayListUnmanaged(CharClass.Range){};
    errdefer ranges.deinit(alloc);

    // Special case: ] as first character is literal
    if (i < input.len and input[i] == ']') {
        try chars.append(alloc, ']');
        i += 1;
    }

    while (i < input.len and input[i] != ']') {
        const c = input[i];

        if (c == '\\' and i + 1 < input.len) {
            // Escaped character
            try chars.append(alloc, input[i + 1]);
            i += 2;
        } else if (i + 2 < input.len and input[i + 1] == '-' and input[i + 2] != ']') {
            // Potential range
            const range_start = c;
            const range_end = input[i + 2];

            // Validate range (must be in order)
            if (range_start <= range_end) {
                try ranges.append(alloc, .{
                    .start = range_start,
                    .end = range_end,
                });
            }
            // Invalid ranges (like [z-a]) are silently ignored per gitignore spec
            i += 3;
        } else {
            try chars.append(alloc, c);
            i += 1;
        }
    }

    // Check for closing bracket
    if (i >= input.len) {
        // No closing bracket - invalid
        return error.InvalidPattern;
    }

    return CharClassResult{
        .class = .{
            .chars = try chars.toOwnedSlice(alloc),
            .ranges = try ranges.toOwnedSlice(alloc),
            .negated = negated,
        },
        .consumed = i + 1, // Include the closing ]
    };
}

// =============================================================================
// Tests
// =============================================================================

test "hasInvalidTrailingBackslash" {
    try std.testing.expect(hasInvalidTrailingBackslash("foo\\"));
    try std.testing.expect(hasInvalidTrailingBackslash("foo\\\\\\"));
    try std.testing.expect(!hasInvalidTrailingBackslash("foo\\\\"));
    try std.testing.expect(!hasInvalidTrailingBackslash("foo"));
    try std.testing.expect(!hasInvalidTrailingBackslash(""));
    try std.testing.expect(hasInvalidTrailingBackslash("\\"));
}

test "processTrailingSpaces" {
    // Unescaped spaces are stripped
    try std.testing.expectEqualStrings("abc", processTrailingSpaces("abc  "));
    try std.testing.expectEqualStrings("abc", processTrailingSpaces("abc "));
    try std.testing.expectEqualStrings("bcd", processTrailingSpaces("bcd  "));

    // Escaped spaces are preserved
    try std.testing.expectEqualStrings("abc\\ ", processTrailingSpaces("abc\\ "));
    try std.testing.expectEqualStrings("cde \\ ", processTrailingSpaces("cde \\ "));

    // Edge cases
    try std.testing.expectEqualStrings("", processTrailingSpaces(""));
    try std.testing.expectEqualStrings("abc", processTrailingSpaces("abc"));
}

test "compile skips empty lines" {
    var compiler = Compiler.init(std.testing.allocator);
    defer compiler.deinit();

    try std.testing.expect(compiler.compile("") == null);
    try std.testing.expect(compiler.compile("   ") == null);
    try std.testing.expect(compiler.compile("\t\t") == null);
}

test "compile skips comments" {
    var compiler = Compiler.init(std.testing.allocator);
    defer compiler.deinit();

    try std.testing.expect(compiler.compile("# comment") == null);
    try std.testing.expect(compiler.compile("#abc") == null);
}

test "compile handles escaped comment" {
    var compiler = Compiler.init(std.testing.allocator);
    defer compiler.deinit();

    const p = compiler.compile("\\#abc");
    try std.testing.expect(p != null);
    try std.testing.expect(!p.?.flags.negated);
}

test "compile handles negation" {
    var compiler = Compiler.init(std.testing.allocator);
    defer compiler.deinit();

    const p = compiler.compile("!*.log");
    try std.testing.expect(p != null);
    try std.testing.expect(p.?.flags.negated);
}

test "compile handles escaped negation" {
    var compiler = Compiler.init(std.testing.allocator);
    defer compiler.deinit();

    const p = compiler.compile("\\!important");
    try std.testing.expect(p != null);
    try std.testing.expect(!p.?.flags.negated);
}

test "compile handles directory-only" {
    var compiler = Compiler.init(std.testing.allocator);
    defer compiler.deinit();

    const p = compiler.compile("build/");
    try std.testing.expect(p != null);
    try std.testing.expect(p.?.flags.dir_only);
}

test "compile handles anchoring" {
    var compiler = Compiler.init(std.testing.allocator);
    defer compiler.deinit();

    // Leading / anchors
    const p1 = compiler.compile("/root.txt");
    try std.testing.expect(p1 != null);
    try std.testing.expect(p1.?.flags.anchored);

    // Internal / anchors
    const p2 = compiler.compile("src/main.zig");
    try std.testing.expect(p2 != null);
    try std.testing.expect(p2.?.flags.anchored);

    // No slash - not anchored
    const p3 = compiler.compile("*.log");
    try std.testing.expect(p3 != null);
    try std.testing.expect(!p3.?.flags.anchored);
}

test "compile handles BOM" {
    var compiler = Compiler.init(std.testing.allocator);
    defer compiler.deinit();

    const p = compiler.compile("\xEF\xBB\xBF*.log");
    try std.testing.expect(p != null);
}

test "compile handles invalid trailing backslash" {
    var compiler = Compiler.init(std.testing.allocator);
    defer compiler.deinit();

    try std.testing.expect(compiler.compile("foo\\") == null);
    try std.testing.expect(compiler.compile("\\") == null);
}

test "compile segments simple pattern" {
    var compiler = Compiler.init(std.testing.allocator);
    defer compiler.deinit();

    const p = compiler.compile("*.log");
    try std.testing.expect(p != null);
    try std.testing.expectEqual(@as(usize, 1), p.?.segments.len);
    try std.testing.expect(!p.?.segments[0].is_globstar);
}

test "compile segments with globstar" {
    var compiler = Compiler.init(std.testing.allocator);
    defer compiler.deinit();

    const p = compiler.compile("**/foo");
    try std.testing.expect(p != null);
    try std.testing.expectEqual(@as(usize, 2), p.?.segments.len);
    try std.testing.expect(p.?.segments[0].is_globstar);
    try std.testing.expect(!p.?.segments[1].is_globstar);
}

test "compile segments path pattern" {
    var compiler = Compiler.init(std.testing.allocator);
    defer compiler.deinit();

    const p = compiler.compile("src/**/*.zig");
    try std.testing.expect(p != null);
    try std.testing.expectEqual(@as(usize, 3), p.?.segments.len);
    try std.testing.expect(!p.?.segments[0].is_globstar);
    try std.testing.expect(p.?.segments[1].is_globstar);
    try std.testing.expect(!p.?.segments[2].is_globstar);
}

test "parseCharClass basic" {
    const result = try parseCharClass(std.testing.allocator, "[abc]");
    defer std.testing.allocator.free(result.class.chars);
    defer std.testing.allocator.free(result.class.ranges);

    try std.testing.expectEqualStrings("abc", result.class.chars);
    try std.testing.expectEqual(@as(usize, 0), result.class.ranges.len);
    try std.testing.expect(!result.class.negated);
    try std.testing.expectEqual(@as(usize, 5), result.consumed);
}

test "parseCharClass negated" {
    const result = try parseCharClass(std.testing.allocator, "[!abc]");
    defer std.testing.allocator.free(result.class.chars);
    defer std.testing.allocator.free(result.class.ranges);

    try std.testing.expectEqualStrings("abc", result.class.chars);
    try std.testing.expect(result.class.negated);
}

test "parseCharClass with range" {
    const result = try parseCharClass(std.testing.allocator, "[a-z]");
    defer std.testing.allocator.free(result.class.chars);
    defer std.testing.allocator.free(result.class.ranges);

    try std.testing.expectEqual(@as(usize, 0), result.class.chars.len);
    try std.testing.expectEqual(@as(usize, 1), result.class.ranges.len);
    try std.testing.expectEqual(@as(u8, 'a'), result.class.ranges[0].start);
    try std.testing.expectEqual(@as(u8, 'z'), result.class.ranges[0].end);
}

test "parseCharClass invalid range ignored" {
    // [z-a] is an invalid range and should be silently ignored
    const result = try parseCharClass(std.testing.allocator, "[z-a]");
    defer std.testing.allocator.free(result.class.chars);
    defer std.testing.allocator.free(result.class.ranges);

    try std.testing.expectEqual(@as(usize, 0), result.class.ranges.len);
}

test "parseCharClass no closing bracket" {
    const result = parseCharClass(std.testing.allocator, "[abc");
    try std.testing.expect(result == error.InvalidPattern);
}
