//! ignore-zig: Gitignore pattern matching library
//!
//! High-performance Zig implementation of gitignore pattern matching,
//! compatible with node-ignore semantics.
//!
//! ## Quick Start
//!
//! ```zig
//! const ignore = @import("ignore_zig");
//!
//! var ig = ignore.Ignore.init(allocator, .{});
//! defer ig.deinit();
//!
//! try ig.add("*.log\nnode_modules/\n!important.log");
//!
//! if (ig.ignores("debug.log")) {
//!     // File should be ignored
//! }
//! ```
//!
//! ## Zero-Copy Mode
//!
//! For maximum performance when content lifetime is managed externally:
//!
//! ```zig
//! try ig.addZeroCopy(file_content);  // content must outlive ig
//! ```
//!
//! ## Features
//!
//! - Full gitignore specification support
//! - Wildcards: `*`, `**`, `?`
//! - Character classes: `[abc]`, `[a-z]`, `[!abc]`
//! - Negation patterns: `!important.log`
//! - Directory-only patterns: `build/`
//! - Anchored patterns: `/root.txt`
//! - Escaped characters: `\*`, `\ `, `\!`, `\#`
//! - Parent directory exclusion semantics
//! - Arena allocator: O(1) cleanup
//! - Zero heap allocation during matching

const std = @import("std");

// Core modules
pub const ignore = @import("ignore.zig");
pub const pattern = @import("pattern.zig");
pub const compiler = @import("compiler.zig");
pub const matcher = @import("matcher.zig");

// Primary export
pub const Ignore = ignore.Ignore;
pub const Options = Ignore.Options;

// Pattern types (for advanced use)
pub const Pattern = pattern.Pattern;
pub const PatternFlags = pattern.PatternFlags;
pub const Segment = pattern.Segment;
pub const Element = pattern.Element;
pub const CharClass = pattern.CharClass;

// Compiler (for advanced use)
pub const Compiler = compiler.Compiler;

// Matcher utilities
pub const MatchOptions = matcher.MatchOptions;
pub const isValidPath = matcher.isValidPath;
pub const matchPattern = matcher.matchPattern;

/// Default patterns commonly used in gitignore files
pub const default_patterns =
    \\.git/
    \\.hg/
    \\.svn/
    \\node_modules/
    \\__pycache__/
    \\.zig-cache/
    \\zig-out/
    \\target/
    \\build/
    \\dist/
    \\vendor/
    \\.DS_Store
    \\*.pyc
    \\*.o
    \\*.a
    \\*.so
    \\*.dylib
;

/// Load gitignore patterns from a file
pub fn fromFile(allocator: std.mem.Allocator, path: []const u8) !Ignore {
    return fromFileWithOptions(allocator, path, .{});
}

/// Load gitignore patterns from a file with custom options
pub fn fromFileWithOptions(allocator: std.mem.Allocator, path: []const u8, options: Options) !Ignore {
    var ig = Ignore.init(allocator, options);
    errdefer ig.deinit();

    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    try ig.add(content);
    return ig;
}

/// Load patterns from multiple ignore files in a directory
pub fn fromDir(allocator: std.mem.Allocator, dir_path: []const u8) !Ignore {
    return fromDirWithOptions(allocator, dir_path, .{}, &[_][]const u8{".gitignore"});
}

/// Load patterns from multiple ignore files in a directory with options
pub fn fromDirWithOptions(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    options: Options,
    ignore_files: []const []const u8,
) !Ignore {
    var ig = Ignore.init(allocator, options);
    errdefer ig.deinit();

    for (ignore_files) |filename| {
        const full_path = try std.fs.path.join(allocator, &.{ dir_path, filename });
        defer allocator.free(full_path);

        const file = std.fs.cwd().openFile(full_path, .{}) catch continue;
        defer file.close();

        const content = file.readToEndAlloc(allocator, 1024 * 1024) catch continue;
        defer allocator.free(content);

        try ig.add(content);
    }

    return ig;
}

/// Create an Ignore instance with default patterns pre-loaded
pub fn withDefaults(allocator: std.mem.Allocator) !Ignore {
    return withDefaultsAndOptions(allocator, .{});
}

/// Create an Ignore instance with default patterns and custom options
pub fn withDefaultsAndOptions(allocator: std.mem.Allocator, options: Options) !Ignore {
    var ig = Ignore.init(allocator, options);
    errdefer ig.deinit();

    try ig.add(default_patterns);
    return ig;
}

// =============================================================================
// Tests
// =============================================================================

test "basic" {
    var ig = Ignore.init(std.testing.allocator, .{});
    defer ig.deinit();

    try ig.add("*.log");
    try std.testing.expect(ig.ignores("test.log"));
}

test "withDefaults" {
    var ig = try withDefaults(std.testing.allocator);
    defer ig.deinit();

    try std.testing.expect(ig.ignores(".git/"));
    try std.testing.expect(ig.ignores("node_modules/"));
    try std.testing.expect(ig.ignores(".DS_Store"));
    try std.testing.expect(ig.ignores("file.pyc"));
}

test {
    _ = @import("pattern.zig");
    _ = @import("compiler.zig");
    _ = @import("matcher.zig");
    _ = @import("ignore.zig");
    _ = @import("tests.zig");
}
