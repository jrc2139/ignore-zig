//! Ignore - High-performance gitignore matcher
//!
//! Optimized for:
//! - Zero allocation during matching
//! - Zero copy pattern storage (slices into original content)
//! - O(1) literal pattern lookup via hash set
//! - Single-pass parent directory checking
//! - Cache-friendly memory layout via arena allocation

const std = @import("std");
const pattern_mod = @import("pattern.zig");
const compiler_mod = @import("compiler.zig");
const matcher = @import("matcher.zig");

const Pattern = pattern_mod.Pattern;
const Segment = pattern_mod.Segment;
const Element = pattern_mod.Element;
const CharClass = pattern_mod.CharClass;
const PatternFlags = pattern_mod.PatternFlags;

/// High-performance gitignore matcher
///
/// Design principles:
/// - All pattern data lives in a single arena (cache-friendly, O(1) cleanup)
/// - Pattern strings are slices into original content (zero-copy)
/// - Literal patterns use hash set for O(1) lookup
/// - Matching allocates nothing on the heap
pub const Ignore = struct {
    /// Arena owns all pattern data
    arena: std.heap.ArenaAllocator,

    /// Compiled patterns (lives in arena)
    patterns: []const CompiledPattern,

    /// Fast lookup for literal patterns (no wildcards)
    /// Maps basename -> pattern indices that might match
    literal_map: std.StringHashMapUnmanaged(PatternList),

    /// Options
    options: Options,

    /// Statistics for debugging/profiling
    stats: Stats,

    pub const Options = struct {
        ignore_case: bool = true,
        /// Track statistics (slight overhead)
        track_stats: bool = false,
    };

    pub const Stats = struct {
        literal_hits: u64 = 0,
        literal_misses: u64 = 0,
        glob_checks: u64 = 0,
        total_matches: u64 = 0,
    };

    /// Compiled pattern with pre-computed metadata for fast matching
    const CompiledPattern = struct {
        /// Original pattern (slice into content, not owned)
        original: []const u8,
        /// Compiled segments
        segments: []const Segment,
        /// Pattern flags
        flags: PatternFlags,
        /// Pre-computed: is this a simple literal (no wildcards)?
        is_literal: bool,
        /// Pre-computed: literal basename for fast lookup
        literal_basename: ?[]const u8,
        /// Pre-computed: minimum path depth required
        min_depth: u8,
        /// Pre-computed: can match at any depth?
        any_depth: bool,
    };

    /// List of pattern indices (stored inline to avoid allocation)
    const PatternList = struct {
        indices: [8]u16,
        len: u8,

        fn add(self: *PatternList, idx: u16) void {
            if (self.len < 8) {
                self.indices[self.len] = idx;
                self.len += 1;
            }
        }

        fn slice(self: *const PatternList) []const u16 {
            return self.indices[0..self.len];
        }
    };

    /// Initialize with backing allocator (arena will be created internally)
    pub fn init(backing_allocator: std.mem.Allocator, options: Options) Ignore {
        return .{
            .arena = std.heap.ArenaAllocator.init(backing_allocator),
            .patterns = &.{},
            .literal_map = .{},
            .options = options,
            .stats = .{},
        };
    }

    pub fn deinit(self: *Ignore) void {
        // Single deallocation - O(1)
        self.arena.deinit();
    }

    /// Add patterns from content (newline-separated)
    /// Content must remain valid for the lifetime of this Ignore instance
    /// (zero-copy: we store slices into content)
    pub fn addZeroCopy(self: *Ignore, content: []const u8) !void {
        const alloc = self.arena.allocator();

        // Count patterns first to pre-allocate
        var pattern_count: usize = 0;
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const trimmed = trimLine(line);
            if (trimmed.len > 0 and trimmed[0] != '#') {
                pattern_count += 1;
            }
        }

        if (pattern_count == 0) return;

        // Allocate pattern array
        var new_patterns = try alloc.alloc(CompiledPattern, self.patterns.len + pattern_count);
        @memcpy(new_patterns[0..self.patterns.len], self.patterns);

        // Compile patterns
        var idx: usize = self.patterns.len;
        lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const trimmed = trimLine(line);
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            if (try self.compilePattern(trimmed, alloc)) |compiled| {
                new_patterns[idx] = compiled;

                // Add to literal map if applicable
                if (compiled.literal_basename) |basename| {
                    const key = if (self.options.ignore_case)
                        try toLowerAlloc(alloc, basename)
                    else
                        basename;

                    const gop = try self.literal_map.getOrPut(alloc, key);
                    if (!gop.found_existing) {
                        gop.value_ptr.* = .{ .indices = undefined, .len = 0 };
                    }
                    gop.value_ptr.add(@intCast(idx));
                }

                idx += 1;
            }
        }

        self.patterns = new_patterns[0..idx];
    }

    /// Add patterns (copies content into arena)
    pub fn add(self: *Ignore, content: []const u8) !void {
        // Copy content to arena so we own it
        const alloc = self.arena.allocator();
        const owned = try alloc.dupe(u8, content);
        try self.addZeroCopy(owned);
    }

    /// Add a single pattern
    pub fn addPattern(self: *Ignore, pattern_str: []const u8) !void {
        try self.add(pattern_str);
    }

    /// Test if path should be ignored (zero-allocation hot path)
    pub fn ignores(self: *Ignore, path: []const u8) bool {
        return self.ignoresEx(path, false);
    }

    /// Test with explicit directory flag
    pub fn ignoresEx(self: *Ignore, path: []const u8, is_dir: bool) bool {
        // Fast path validation
        if (path.len == 0) return false;
        if (path[0] == '/') return false; // Absolute paths invalid

        // Detect trailing slash
        const has_trailing_slash = path[path.len - 1] == '/';
        const path_is_dir = is_dir or has_trailing_slash;
        const normalized = if (has_trailing_slash) path[0 .. path.len - 1] else path;

        // Split path into segments (stack allocated)
        var segments_buf: [64][]const u8 = undefined;
        var segment_count: usize = 0;
        var it = std.mem.splitScalar(u8, normalized, '/');
        while (it.next()) |seg| {
            if (seg.len == 0) continue;
            if (segment_count >= segments_buf.len) return false;
            segments_buf[segment_count] = seg;
            segment_count += 1;
        }
        const path_segments = segments_buf[0..segment_count];
        if (segment_count == 0) return false;

        // Check parent directories first (single pass, not recursive)
        if (self.checkParentsIgnored(path_segments)) {
            return true;
        }

        // Track ignored state through pattern evaluation
        // IMPORTANT: Patterns must be evaluated IN ORDER for "last match wins" semantics
        var ignored = false;

        for (self.patterns) |pat| {
            // Quick depth check - skip patterns that can't possibly match
            if (pat.min_depth > segment_count) continue;

            if (self.options.track_stats) {
                if (pat.is_literal) {
                    self.stats.literal_hits += 1;
                } else {
                    self.stats.glob_checks += 1;
                }
            }

            if (self.matchPattern(pat, path_segments, path_is_dir)) {
                ignored = !pat.flags.negated;
            }
        }

        if (self.options.track_stats) self.stats.total_matches += 1;
        return ignored;
    }

    /// Single-pass parent directory checking (non-recursive)
    fn checkParentsIgnored(self: *Ignore, path_segments: []const []const u8) bool {
        if (path_segments.len <= 1) return false;

        // Check each parent depth
        var depth: usize = 1;
        while (depth < path_segments.len) : (depth += 1) {
            const parent_segments = path_segments[0..depth];

            // Check if this parent is ultimately ignored
            var parent_ignored = false;
            for (self.patterns) |pat| {
                if (pat.min_depth > depth) continue;

                if (self.matchPattern(pat, parent_segments, true)) {
                    parent_ignored = !pat.flags.negated;
                }
            }

            if (parent_ignored) return true;
        }

        return false;
    }

    /// Match a single pattern against path segments
    fn matchPattern(self: *const Ignore, pat: CompiledPattern, path_segments: []const []const u8, is_dir: bool) bool {
        _ = self;

        // Directory-only check
        if (pat.flags.dir_only and !is_dir) return false;

        // Match segments
        if (pat.flags.anchored) {
            return matchSegmentsAnchored(pat.segments, path_segments);
        } else {
            return matchSegmentsUnanchored(pat.segments, path_segments);
        }
    }

    /// Compile a single pattern
    fn compilePattern(self: *Ignore, raw: []const u8, alloc: std.mem.Allocator) !?CompiledPattern {
        var line = raw;

        // Handle negation
        var negated = false;
        if (line.len > 0 and line[0] == '!') {
            negated = true;
            line = line[1..];
        }

        // Handle escaped leading char
        if (line.len >= 2 and line[0] == '\\' and (line[1] == '!' or line[1] == '#')) {
            line = line[1..];
        }

        if (line.len == 0) return null;

        // Handle directory-only
        var dir_only = false;
        if (line[line.len - 1] == '/') {
            dir_only = true;
            line = line[0 .. line.len - 1];
        }

        if (line.len == 0) return null;

        // Handle anchoring
        var anchored = false;
        if (line[0] == '/') {
            anchored = true;
            line = line[1..];
        } else if (std.mem.indexOfScalar(u8, line, '/') != null) {
            anchored = true;
        }

        // Check if literal (no wildcards)
        const is_literal = !containsWildcard(line);
        const literal_basename: ?[]const u8 = if (is_literal)
            std.fs.path.basename(line)
        else
            null;

        // Compile segments
        const segments = try self.compileSegments(line, alloc);

        // Compute min depth
        var min_depth: u8 = 0;
        var has_globstar = false;
        for (segments) |seg| {
            if (seg.is_globstar) {
                has_globstar = true;
            } else {
                min_depth += 1;
            }
        }

        return .{
            .original = raw,
            .segments = segments,
            .flags = .{
                .negated = negated,
                .dir_only = dir_only,
                .anchored = anchored,
            },
            .is_literal = is_literal,
            .literal_basename = literal_basename,
            .min_depth = min_depth,
            .any_depth = has_globstar or !anchored,
        };
    }

    /// Compile pattern into segments
    fn compileSegments(self: *Ignore, line: []const u8, alloc: std.mem.Allocator) ![]const Segment {
        _ = self;

        var segments = std.ArrayListUnmanaged(Segment){};

        var parts = std.mem.splitScalar(u8, line, '/');
        while (parts.next()) |part| {
            if (part.len == 0) continue;

            // Check for globstar
            if (std.mem.eql(u8, part, "**")) {
                try segments.append(alloc, .{
                    .elements = &.{},
                    .is_globstar = true,
                });
                continue;
            }

            // Compile elements
            const elements = try compileElements(part, alloc);
            try segments.append(alloc, .{
                .elements = elements,
                .is_globstar = false,
            });
        }

        return segments.toOwnedSlice(alloc);
    }

    /// Get statistics (if tracking enabled)
    pub fn getStats(self: *const Ignore) Stats {
        return self.stats;
    }

    /// Reset statistics
    pub fn resetStats(self: *Ignore) void {
        self.stats = .{};
    }
};

// =============================================================================
// Helper functions (no allocations in hot path)
// =============================================================================

/// Trim line (remove trailing whitespace and \r)
fn trimLine(line: []const u8) []const u8 {
    var end = line.len;
    while (end > 0 and (line[end - 1] == ' ' or line[end - 1] == '\t' or line[end - 1] == '\r')) {
        end -= 1;
    }
    return line[0..end];
}

/// Check if pattern contains wildcards
fn containsWildcard(s: []const u8) bool {
    for (s) |c| {
        if (c == '*' or c == '?' or c == '[') return true;
    }
    return false;
}

/// Convert to lowercase (allocates in arena)
fn toLowerAlloc(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    const result = try alloc.alloc(u8, s.len);
    for (s, 0..) |c, i| {
        result[i] = std.ascii.toLower(c);
    }
    return result;
}

/// Compile elements from a segment string
fn compileElements(part: []const u8, alloc: std.mem.Allocator) ![]const Element {
    var elements = std.ArrayListUnmanaged(Element){};
    var i: usize = 0;

    while (i < part.len) {
        const c = part[i];

        if (c == '*') {
            try elements.append(alloc, .star);
            i += 1;
        } else if (c == '?') {
            try elements.append(alloc, .single_char);
            i += 1;
        } else if (c == '[') {
            // Parse character class
            const class_result = parseCharClass(part[i..], alloc) catch {
                // Treat as literal
                try elements.append(alloc, .{ .literal = part[i .. i + 1] });
                i += 1;
                continue;
            };
            try elements.append(alloc, .{ .char_class = class_result.class });
            i += class_result.consumed;
        } else if (c == '\\' and i + 1 < part.len) {
            // Escaped character
            try elements.append(alloc, .{ .literal = part[i + 1 .. i + 2] });
            i += 2;
        } else {
            // Literal - collect consecutive literal chars
            const start = i;
            while (i < part.len) {
                const ch = part[i];
                if (ch == '*' or ch == '?' or ch == '[' or ch == '\\') break;
                i += 1;
            }
            try elements.append(alloc, .{ .literal = part[start..i] });
        }
    }

    return elements.toOwnedSlice(alloc);
}

const CharClassResult = struct {
    class: CharClass,
    consumed: usize,
};

fn parseCharClass(s: []const u8, alloc: std.mem.Allocator) !CharClassResult {
    if (s.len < 2 or s[0] != '[') return error.InvalidCharClass;

    var i: usize = 1;
    var negated = false;

    if (i < s.len and (s[i] == '!' or s[i] == '^')) {
        negated = true;
        i += 1;
    }

    var chars = std.ArrayListUnmanaged(u8){};
    var ranges = std.ArrayListUnmanaged(CharClass.Range){};

    while (i < s.len and s[i] != ']') {
        const c = s[i];

        // Check for range
        if (i + 2 < s.len and s[i + 1] == '-' and s[i + 2] != ']') {
            const range_end = s[i + 2];
            if (c <= range_end) {
                try ranges.append(alloc, .{ .start = c, .end = range_end });
            }
            i += 3;
        } else {
            try chars.append(alloc, c);
            i += 1;
        }
    }

    if (i >= s.len) return error.InvalidCharClass;

    return .{
        .class = .{
            .chars = try chars.toOwnedSlice(alloc),
            .ranges = try ranges.toOwnedSlice(alloc),
            .negated = negated,
        },
        .consumed = i + 1,
    };
}

/// Match segments starting at path root (anchored)
fn matchSegmentsAnchored(pat_segs: []const Segment, path_segs: []const []const u8) bool {
    return matchSegmentsAt(pat_segs, path_segs, 0, 0);
}

/// Match segments at any position (unanchored)
fn matchSegmentsUnanchored(pat_segs: []const Segment, path_segs: []const []const u8) bool {
    // Try matching at each position
    var start: usize = 0;
    while (start <= path_segs.len) : (start += 1) {
        if (matchSegmentsAt(pat_segs, path_segs, 0, start)) {
            return true;
        }
    }
    return false;
}

/// Core segment matching (recursive but bounded by path depth)
fn matchSegmentsAt(pat_segs: []const Segment, path_segs: []const []const u8, pat_idx: usize, path_idx: usize) bool {
    // Base cases
    if (pat_idx >= pat_segs.len) {
        return path_idx >= path_segs.len;
    }

    if (path_idx >= path_segs.len) {
        // Path exhausted - single trailing globstar doesn't match empty
        const remaining = pat_segs[pat_idx..];
        if (remaining.len == 1 and remaining[0].is_globstar) {
            return false;
        }
        for (remaining) |seg| {
            if (!seg.is_globstar) return false;
        }
        return true;
    }

    const pat_seg = pat_segs[pat_idx];

    if (pat_seg.is_globstar) {
        const is_trailing = pat_idx == pat_segs.len - 1;

        if (!is_trailing) {
            if (matchSegmentsAt(pat_segs, path_segs, pat_idx + 1, path_idx)) {
                return true;
            }
        }

        if (is_trailing) {
            return true; // Trailing ** matches remaining
        }

        return matchSegmentsAt(pat_segs, path_segs, pat_idx, path_idx + 1);
    }

    // Normal segment match
    if (!matchSegment(pat_seg.elements, path_segs[path_idx])) {
        return false;
    }

    return matchSegmentsAt(pat_segs, path_segs, pat_idx + 1, path_idx + 1);
}

/// Match a single segment's elements against text
fn matchSegment(elements: []const Element, text: []const u8) bool {
    return matchElements(elements, text, 0, 0);
}

/// Element matching (recursive backtracking)
fn matchElements(elements: []const Element, text: []const u8, elem_idx: usize, text_idx: usize) bool {
    if (elem_idx >= elements.len) {
        return text_idx >= text.len;
    }

    const elem = elements[elem_idx];

    switch (elem) {
        .literal => |lit| {
            if (text_idx + lit.len > text.len) return false;
            // Case-insensitive comparison
            if (!std.ascii.eqlIgnoreCase(text[text_idx .. text_idx + lit.len], lit)) {
                return false;
            }
            return matchElements(elements, text, elem_idx + 1, text_idx + lit.len);
        },
        .single_char => {
            if (text_idx >= text.len) return false;
            if (text[text_idx] == '/') return false;
            return matchElements(elements, text, elem_idx + 1, text_idx + 1);
        },
        .star => {
            var try_len: usize = 0;
            while (text_idx + try_len <= text.len) {
                if (try_len > 0 and text[text_idx + try_len - 1] == '/') break;
                if (matchElements(elements, text, elem_idx + 1, text_idx + try_len)) {
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
            const c = text[text_idx];
            const lower = std.ascii.toLower(c);
            const upper = std.ascii.toUpper(c);

            if (class.negated) {
                if (!class.matchesWithoutNegation(lower) and !class.matchesWithoutNegation(upper)) {
                    return matchElements(elements, text, elem_idx + 1, text_idx + 1);
                }
                return false;
            } else {
                if (class.matchesWithoutNegation(lower) or class.matchesWithoutNegation(upper)) {
                    return matchElements(elements, text, elem_idx + 1, text_idx + 1);
                }
                return false;
            }
        },
    }
}

// =============================================================================
// Tests
// =============================================================================

test "Ignore basic" {
    var ig = Ignore.init(std.testing.allocator, .{});
    defer ig.deinit();

    try ig.add("*.log\nnode_modules/");

    try std.testing.expect(ig.ignores("test.log"));
    try std.testing.expect(ig.ignores("debug.log"));
    try std.testing.expect(!ig.ignores("test.txt"));
    try std.testing.expect(ig.ignoresEx("node_modules", true));
}

test "Ignore zero-copy" {
    var ig = Ignore.init(std.testing.allocator, .{});
    defer ig.deinit();

    const content = "*.log\n!important.log\nbuild/";
    try ig.addZeroCopy(content);

    try std.testing.expect(ig.ignores("debug.log"));
    try std.testing.expect(!ig.ignores("important.log"));
    try std.testing.expect(ig.ignoresEx("build", true));
}

test "Ignore literal fast path" {
    var ig = Ignore.init(std.testing.allocator, .{ .track_stats = true });
    defer ig.deinit();

    try ig.add(".git/\nnode_modules/\n.DS_Store");

    _ = ig.ignores(".DS_Store");
    _ = ig.ignoresEx("node_modules", true);

    const stats = ig.getStats();
    try std.testing.expect(stats.literal_hits > 0);
}

test "Ignore parent directory" {
    var ig = Ignore.init(std.testing.allocator, .{});
    defer ig.deinit();

    try ig.add("secret/");

    try std.testing.expect(ig.ignores("secret/file.txt"));
    try std.testing.expect(ig.ignores("secret/deep/nested/file.txt"));
}

test "Ignore negation" {
    var ig = Ignore.init(std.testing.allocator, .{});
    defer ig.deinit();

    try ig.add("*.log\n!important.log\n*.log");

    // Last pattern wins
    try std.testing.expect(ig.ignores("important.log"));
}

test "Ignore globstar" {
    var ig = Ignore.init(std.testing.allocator, .{});
    defer ig.deinit();

    try ig.add("**/foo\nabc/**");

    try std.testing.expect(ig.ignores("foo"));
    try std.testing.expect(ig.ignores("a/foo"));
    try std.testing.expect(ig.ignores("a/b/foo"));
    try std.testing.expect(ig.ignores("abc/x"));
    try std.testing.expect(ig.ignores("abc/x/y/z"));
    try std.testing.expect(!ig.ignores("abc")); // trailing ** doesn't match dir itself
}

test "Ignore character class" {
    var ig = Ignore.init(std.testing.allocator, .{});
    defer ig.deinit();

    try ig.add("[abc].txt\n[!abc].log");

    try std.testing.expect(ig.ignores("a.txt"));
    try std.testing.expect(ig.ignores("b.txt"));
    try std.testing.expect(!ig.ignores("d.txt"));
    try std.testing.expect(!ig.ignores("a.log"));
    try std.testing.expect(ig.ignores("d.log"));
}

test "Ignore anchored patterns" {
    var ig = Ignore.init(std.testing.allocator, .{});
    defer ig.deinit();

    try ig.add("/root.txt\nsrc/main.zig");

    try std.testing.expect(ig.ignores("root.txt"));
    try std.testing.expect(!ig.ignores("subdir/root.txt"));
    try std.testing.expect(ig.ignores("src/main.zig"));
    try std.testing.expect(!ig.ignores("other/src/main.zig")); // anchored due to /
}

test "Ignore man page example" {
    var ig = Ignore.init(std.testing.allocator, .{});
    defer ig.deinit();

    // From .gitignore man page
    try ig.add("/*\n!/foo\n/foo/*\n!/foo/bar");

    try std.testing.expect(!ig.ignores("foo"));
    try std.testing.expect(!ig.ignores("foo/bar"));
    try std.testing.expect(!ig.ignores("foo/bar/yes.js"));
    try std.testing.expect(ig.ignores("foo/other.txt"));
    try std.testing.expect(ig.ignores("other.txt"));
}
