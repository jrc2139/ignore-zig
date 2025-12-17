# ignore-zig

High-performance gitignore pattern matching library for Zig, compatible with node-ignore semantics.

## Features

- Full gitignore specification support
- Wildcards: `*`, `**`, `?`
- Character classes: `[abc]`, `[a-z]`, `[!abc]`
- Negation patterns: `!important.log`
- Directory-only patterns: `build/`
- Anchored patterns: `/root.txt`
- Escaped characters: `\*`, `\ `, `\!`, `\#`
- Parent directory exclusion semantics
- Arena allocator: O(1) cleanup
- Zero heap allocation during matching
- Zero-copy mode for maximum performance

## Requirements

- Zig 0.15.0 or later

## Installation

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .ignore_zig = .{
        .url = "https://github.com/jrc2139/ignore-zig/archive/refs/heads/main.tar.gz",
        .hash = "...",
    },
},
```

Then in your `build.zig`:

```zig
const ignore_zig = b.dependency("ignore_zig", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("ignore_zig", ignore_zig.module("ignore_zig"));
```

## Quick Start

```zig
const std = @import("std");
const ignore = @import("ignore_zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ig = ignore.Ignore.init(allocator, .{});
    defer ig.deinit();

    try ig.add("*.log\nnode_modules/\n!important.log");

    if (ig.ignores("debug.log")) {
        std.debug.print("debug.log is ignored\n", .{});
    }

    if (!ig.ignores("important.log")) {
        std.debug.print("important.log is NOT ignored\n", .{});
    }
}
```

## API

### `Ignore`

The main type for matching gitignore patterns.

```zig
// Initialize with allocator and options
var ig = ignore.Ignore.init(allocator, .{
    .ignore_case = true,      // Case-insensitive matching (default: true)
    .track_stats = false,     // Enable statistics tracking
});
defer ig.deinit();

// Add patterns (copies content)
try ig.add("*.log\nnode_modules/");

// Add a single pattern
try ig.addPattern("*.tmp");

// Check if a path should be ignored
const ignored = ig.ignores("debug.log");

// Check with explicit directory flag
const ignored_dir = ig.ignoresEx("build", true);
```

### Zero-Copy Mode

For maximum performance when content lifetime is managed externally:

```zig
// Content must outlive the Ignore instance
const content = try file.readToEndAlloc(allocator, max_size);
defer allocator.free(content);

try ig.addZeroCopy(content);
```

### Convenience Functions

```zig
// Load patterns from a .gitignore file
var ig = try ignore.fromFile(allocator, ".gitignore");
defer ig.deinit();

// Load patterns from multiple ignore files in a directory
var ig = try ignore.fromDir(allocator, "/path/to/project");
defer ig.deinit();

// Create with common default patterns pre-loaded
var ig = try ignore.withDefaults(allocator);
defer ig.deinit();
```

### Default Patterns

The library includes common default patterns:

```
.git/
.hg/
.svn/
node_modules/
__pycache__/
.zig-cache/
zig-out/
target/
build/
dist/
vendor/
.DS_Store
*.pyc
*.o
*.a
*.so
*.dylib
```

## Pattern Syntax

| Pattern | Description |
|---------|-------------|
| `*.log` | Match any file ending in `.log` |
| `build/` | Match directory named `build` |
| `/root.txt` | Match `root.txt` only at repository root |
| `!important.log` | Negate: don't ignore `important.log` |
| `**/foo` | Match `foo` at any depth |
| `abc/**` | Match everything inside `abc/` |
| `a/**/b` | Match `a/b`, `a/x/b`, `a/x/y/b`, etc. |
| `?.txt` | Match single character + `.txt` |
| `[abc].txt` | Match `a.txt`, `b.txt`, or `c.txt` |
| `[a-z].txt` | Match any lowercase letter + `.txt` |
| `[!abc].txt` | Match any char except `a`, `b`, `c` + `.txt` |
| `\!file` | Escape: match file named `!file` |

## Build Commands

```bash
# Run tests
zig build test

# Check for compilation errors (fast)
zig build check

# Format source code
zig fmt src/
```

## Architecture

```
src/
├── lib.zig       # Public API and convenience functions
├── ignore.zig    # Core Ignore type and matching logic
├── pattern.zig   # Pattern types (Segment, Element, CharClass)
├── compiler.zig  # Pattern compilation
├── matcher.zig   # Low-level matching utilities
└── tests.zig     # Integration tests
```

## Performance

The library is optimized for:

- **Zero allocation during matching**: All matching operations use stack-allocated buffers
- **Zero-copy pattern storage**: Patterns store slices into original content
- **O(1) literal pattern lookup**: Hash set for patterns without wildcards
- **Cache-friendly memory layout**: Single arena allocation for all pattern data
- **Single-pass parent directory checking**: Efficient directory exclusion

## License

MIT
