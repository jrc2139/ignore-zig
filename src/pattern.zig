//! Pattern types for gitignore parsing
//!
//! This module defines the internal representation of compiled gitignore patterns.
//! Patterns are parsed once and matched many times, so we use a compiled
//! segment-based representation rather than regex.

const std = @import("std");

/// Errors that can occur during pattern operations
pub const PatternError = error{
    OutOfMemory,
    InvalidPattern,
    InvalidCharacterRange,
};

/// A character class like [abc], [a-z], or [!abc]
pub const CharClass = struct {
    /// Individual characters to match
    chars: []const u8,
    /// Character ranges (e.g., a-z becomes Range{.start='a', .end='z'})
    ranges: []const Range,
    /// If true, this is a negated class [!...] or [^...]
    negated: bool,

    pub const Range = struct {
        start: u8,
        end: u8,

        /// Check if a character is within this range
        pub fn contains(self: Range, char: u8) bool {
            return char >= self.start and char <= self.end;
        }
    };

    /// Check if a character matches this class
    pub fn matches(self: CharClass, char: u8) bool {
        const in_class = self.matchesWithoutNegation(char);
        return if (self.negated) !in_class else in_class;
    }

    /// Check if a character is in the class, ignoring the negation flag
    pub fn matchesWithoutNegation(self: CharClass, char: u8) bool {
        // Check individual characters
        for (self.chars) |c| {
            if (c == char) return true;
        }

        // Check ranges
        for (self.ranges) |r| {
            if (r.contains(char)) return true;
        }

        return false;
    }
};

/// An element within a pattern segment
pub const Element = union(enum) {
    /// Literal bytes to match exactly
    literal: []const u8,
    /// Star wildcard: matches zero or more characters except '/'
    star,
    /// Question mark: matches exactly one character except '/'
    single_char,
    /// Character class: [abc], [a-z], [!abc]
    char_class: CharClass,
};

/// A segment of a pattern (the parts between '/')
pub const Segment = struct {
    /// The elements that make up this segment
    elements: []const Element,
    /// True if this segment is exactly "**" (globstar)
    is_globstar: bool,

    /// Check if this segment is empty (no elements)
    pub fn isEmpty(self: Segment) bool {
        return self.elements.len == 0 and !self.is_globstar;
    }
};

/// Flags that modify pattern matching behavior
pub const PatternFlags = packed struct {
    /// Pattern started with '!' (negation)
    negated: bool = false,
    /// Pattern ended with '/' (directory-only)
    dir_only: bool = false,
    /// Pattern is anchored (started with '/' or contains internal '/')
    anchored: bool = false,
    /// Reserved for future use
    _reserved: u5 = 0,
};

/// A compiled gitignore pattern
pub const Pattern = struct {
    /// Original pattern string (for debugging/display)
    original: []const u8,
    /// Compiled segments (split by '/')
    segments: []const Segment,
    /// Pattern flags
    flags: PatternFlags,

    /// Check if this pattern is a negation pattern
    pub fn isNegated(self: Pattern) bool {
        return self.flags.negated;
    }

    /// Check if this pattern only matches directories
    pub fn isDirOnly(self: Pattern) bool {
        return self.flags.dir_only;
    }

    /// Check if this pattern is anchored to root
    pub fn isAnchored(self: Pattern) bool {
        return self.flags.anchored;
    }

    /// Get the number of non-globstar segments
    pub fn countNormalSegments(self: Pattern) usize {
        var count: usize = 0;
        for (self.segments) |seg| {
            if (!seg.is_globstar) count += 1;
        }
        return count;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "CharClass.matches basic" {
    const class = CharClass{
        .chars = "abc",
        .ranges = &[_]CharClass.Range{},
        .negated = false,
    };

    try std.testing.expect(class.matches('a'));
    try std.testing.expect(class.matches('b'));
    try std.testing.expect(class.matches('c'));
    try std.testing.expect(!class.matches('d'));
    try std.testing.expect(!class.matches('z'));
}

test "CharClass.matches negated" {
    const class = CharClass{
        .chars = "abc",
        .ranges = &[_]CharClass.Range{},
        .negated = true,
    };

    try std.testing.expect(!class.matches('a'));
    try std.testing.expect(!class.matches('b'));
    try std.testing.expect(!class.matches('c'));
    try std.testing.expect(class.matches('d'));
    try std.testing.expect(class.matches('z'));
}

test "CharClass.matches ranges" {
    const class = CharClass{
        .chars = "",
        .ranges = &[_]CharClass.Range{
            .{ .start = 'a', .end = 'z' },
            .{ .start = '0', .end = '9' },
        },
        .negated = false,
    };

    try std.testing.expect(class.matches('a'));
    try std.testing.expect(class.matches('m'));
    try std.testing.expect(class.matches('z'));
    try std.testing.expect(class.matches('0'));
    try std.testing.expect(class.matches('5'));
    try std.testing.expect(class.matches('9'));
    try std.testing.expect(!class.matches('A'));
    try std.testing.expect(!class.matches('!'));
}

test "CharClass.Range.contains" {
    const range = CharClass.Range{ .start = 'a', .end = 'z' };

    try std.testing.expect(range.contains('a'));
    try std.testing.expect(range.contains('m'));
    try std.testing.expect(range.contains('z'));
    try std.testing.expect(!range.contains('A'));
    try std.testing.expect(!range.contains('0'));
}

test "PatternFlags packed size" {
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(PatternFlags));
}

test "Segment.isEmpty" {
    const empty = Segment{
        .elements = &[_]Element{},
        .is_globstar = false,
    };
    try std.testing.expect(empty.isEmpty());

    const globstar = Segment{
        .elements = &[_]Element{},
        .is_globstar = true,
    };
    try std.testing.expect(!globstar.isEmpty());

    const with_elements = Segment{
        .elements = &[_]Element{.star},
        .is_globstar = false,
    };
    try std.testing.expect(!with_elements.isEmpty());
}
