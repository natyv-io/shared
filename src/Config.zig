//! Parses `conf.natyv.json` -- the per-app declaration of what it's called,
//! where its wasm lives, and which capabilities it needs. Replaces the M5
//! placeholder of passing `app.wasm`'s path and `allowed_hosts` as raw CLI
//! arguments: a real install shouldn't require a developer to remember
//! command-line flags to run someone else's app correctly.
//!
//! The shape here is a deliberate starting point, not a finished schema --
//! expected to grow new capability sections over time (filesystem access,
//! more widget kinds, etc.) as natyv grows more capabilities to declare.

const std = @import("std");

const Self = @This();

pub const SqliteConfig = struct {
    enabled: bool = false,
    /// Filename under the OS-canonical per-app data directory (see
    /// SDL_GetPrefPath in main.zig) -- e.g. "books.sqlite3". Ignored if
    /// `enabled` is false. Deliberately just a filename for now, not a
    /// full per-platform path map -- revisit if/when an app actually needs
    /// to diverge by OS beyond what SDL_GetPrefPath already handles.
    filename: []const u8 = "data.sqlite3",
};

pub const NetworkConfig = struct {
    enabled: bool = false,
    /// Exactly which hosts the guest may reach over HTTP -- the real
    /// security boundary, enforced by Extism's manifest `allowed_hosts`.
    /// Wildcards are supported by that schema. Ignored (treated as no
    /// hosts allowed) if `enabled` is false, regardless of this list --
    /// so flipping `enabled` off is always the fail-safe way to cut
    /// network access entirely, not just an unenforced hint.
    allowed_hosts: []const []const u8 = &.{},
};

pub const WidgetsConfig = struct {
    button: bool = false,
    textfield: bool = false,
    textarea: bool = false,
    label: bool = false,
    checkbox: bool = false,
    toggle: bool = false,
    radio_button: bool = false,
    progress_bar: bool = false,
    slider: bool = false,
    divider: bool = false,
    badge: bool = false,
    numeric_stepper: bool = false,
    segmented_control: bool = false,
};

pub const UiConfig = struct {
    /// `null` (the default) means the app uses the plain, absolute-pixel
    /// `natyv_create_*` widget functions and gets none of the
    /// `natyv_clay_*` ones -- keeps bundles small for apps that don't need
    /// layout, same enforcement story as every other capability here.
    /// `"clay"` is the only recognized value today; `"yoga"` is reserved
    /// for when that backend actually gets built (see project memory).
    backend: ?[]const u8 = null,
};

/// Used both as the window title and as SDL_GetPrefPath's app-name
/// namespace component for where per-app data (e.g. the sqlite file) gets
/// written on disk.
name: []const u8 = "natyv-app",
/// Path to the compiled guest module, resolved relative to this config
/// file's own directory (not the process's cwd) -- see main.zig.
app_wasm: []const u8,
/// The command `natyv prepare`/`natyv build` run to compile this app's own
/// guest source to wasm (e.g. `tinygo build -target wasip1
/// -buildmode=c-shared -o clay-fixture.wasm .`) -- natyv never shells out
/// to N different guest-language compilers itself (see CLAUDE.md's CLI
/// build flow section), it only spawns whatever the dev already uses.
/// Required, same reasoning as `app_wasm`: a real install shouldn't
/// require remembering undocumented flags to build someone else's app
/// correctly. Not yet invoked anywhere -- that's `.ntx` tooling Stage 7
/// (~/.claude/plans/lexical-wishing-penguin.md); this field only exists
/// and validates for now.
wasm_compile: []const u8,
sqlite: SqliteConfig = .{},
network: NetworkConfig = .{},
widgets: WidgetsConfig = .{},
ui: UiConfig = .{},

/// Returns the owning `std.json.Parsed(Self)` -- caller must call
/// `.deinit()` once done with `.value`. `.allocate = .alloc_always` is
/// required, not cosmetic: parseFromSlice's default aliases unescaped
/// strings directly into the source buffer, which `load` frees right after
/// this returns -- the exact use-after-free class of bug hit and fixed in
/// WidgetHost.zig's host functions earlier in this project.
pub fn parseBytes(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Self) {
    return std.json.parseFromSlice(Self, allocator, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
}

pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !std.json.Parsed(Self) {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch {
        return error.ConfigReadFailed;
    };
    defer allocator.free(bytes);
    return parseBytes(allocator, bytes);
}

test "defaults: unspecified sections stay disabled, name/filename fall back" {
    const allocator = std.testing.allocator;
    const parsed = try parseBytes(allocator, "{\"app_wasm\":\"guest/app.wasm\",\"wasm_compile\":\"tinygo build -o app.wasm .\"}");
    defer parsed.deinit();
    try std.testing.expectEqualStrings("natyv-app", parsed.value.name);
    try std.testing.expectEqualStrings("guest/app.wasm", parsed.value.app_wasm);
    try std.testing.expect(!parsed.value.sqlite.enabled);
    try std.testing.expect(!parsed.value.network.enabled);
    try std.testing.expectEqualStrings("data.sqlite3", parsed.value.sqlite.filename);
    try std.testing.expect(!parsed.value.widgets.button);
    try std.testing.expectEqual(@as(?[]const u8, null), parsed.value.ui.backend);
}

test "ui.backend: clay opts an app into the natyv_clay_* host functions" {
    const allocator = std.testing.allocator;
    const parsed = try parseBytes(allocator, "{\"app_wasm\":\"guest/app.wasm\",\"wasm_compile\":\"tinygo build -o app.wasm .\",\"ui\":{\"backend\":\"clay\"}}");
    defer parsed.deinit();
    try std.testing.expectEqualStrings("clay", parsed.value.ui.backend.?);
}

test "app_wasm is required" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.MissingField, parseBytes(allocator, "{\"wasm_compile\":\"tinygo build -o app.wasm .\"}"));
}

test "wasm_compile is required" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.MissingField, parseBytes(allocator, "{\"app_wasm\":\"guest/app.wasm\"}"));
}

test "full config: every section populated" {
    const allocator = std.testing.allocator;
    const parsed = try parseBytes(allocator,
        \\{
        \\  "name": "bookstore",
        \\  "app_wasm": "guest/bookstore.wasm",
        \\  "wasm_compile": "tinygo build -target wasip1 -buildmode=c-shared -o bookstore.wasm .",
        \\  "sqlite": {"enabled": true, "filename": "books.sqlite3"},
        \\  "network": {"enabled": true, "allowed_hosts": ["www.google.com"]},
        \\  "widgets": {"button": true, "textfield": true, "label": true}
        \\}
    );
    defer parsed.deinit();
    try std.testing.expectEqualStrings("bookstore", parsed.value.name);
    try std.testing.expect(parsed.value.sqlite.enabled);
    try std.testing.expectEqualStrings("books.sqlite3", parsed.value.sqlite.filename);
    try std.testing.expect(parsed.value.network.enabled);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.network.allowed_hosts.len);
    try std.testing.expectEqualStrings("www.google.com", parsed.value.network.allowed_hosts[0]);
    try std.testing.expect(parsed.value.widgets.button and parsed.value.widgets.textfield and parsed.value.widgets.label);
}
