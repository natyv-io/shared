//! Parses `conf.natyv.json` -- the per-app declaration of what it's called
//! and which capabilities it needs. Replaces the M5 placeholder of passing
//! `app.wasm`'s path and `allowed_hosts` as raw CLI arguments: a real
//! install shouldn't require a developer to remember command-line flags
//! to run someone else's app correctly.
//!
//! **`app_wasm` was removed as a public field (2026-08-24, the confirmed
//! `.ntx` tooling Stage 7 breaking change)** -- `natyv build` now always
//! bundles the compiled wasm directly into the natyv-core binary via
//! `@embedFile` (see `src/cli/Bundle.zig`/`build.zig`'s
//! `-Dembed-app-wasm`), so a dev-configured runtime disk path is no
//! longer the real mechanism. The underlying "read wasm bytes from a
//! file" code survives in `main.zig` for local dev/testing (running
//! natyv-core directly against an example without a full `natyv build`
//! round trip) -- it now derives the filename from `name` via
//! `wasmFilename` below (`<name>.wasm`, the same convention `app_wasm`
//! always held in practice) instead of reading a separate config key.
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

/// One C library `natyv bind` should generate Extism host-function
/// trampolines + guest-wrapper code for -- Stage 2.1 of
/// ~/.claude/plans/lexical-wishing-penguin.md. Written/updated by `natyv
/// get` (not built yet); consumed by `natyv bind` (`src/cli/Bind.zig`).
/// Only the "externally linked" mode for now (a library that's already
/// compiled somewhere `link` can resolve) -- a second "locally vendored"
/// mode (a list of `.c` sources `natyv bind` compiles directly, no `link`
/// needed) is a real, still-open future field set, not added until a real
/// vendoring case actually needs it.
pub const BindingEntry = struct {
    /// Names this entry -- drives the generated Zig handle-table/native-
    /// callback variable names and the generated Go package name (see
    /// `src/bindgen/Codegen.zig`'s own doc comment on why these can't be
    /// hardcoded once more than one library can be bound).
    library: []const u8,
    /// The exact string handed to `@cInclude` when `natyv bind` generates
    /// this entry's scratch reflector program.
    header: []const u8,
    /// Real `-I` include paths the reflector (and, per Stage 1's own
    /// still-open architecture question, the eventual per-app natyv-core
    /// rebuild) needs to actually resolve `header`.
    include_dirs: []const []const u8 = &.{},
    /// Real `-L` library search paths -- needed for anything not on the
    /// linker's default search path (e.g. a Homebrew keg-only library like
    /// `zlib` itself). Added in Stage 2.4 once `pkg-config --libs` output
    /// (which routinely includes these) needed somewhere to go -- `link`
    /// only ever holds bare library names, matching `build.zig`'s
    /// `linkSystemLibrary(name)` convention.
    lib_dirs: []const []const u8 = &.{},
    /// Real linker flags needed to resolve the library's actual compiled
    /// implementation (e.g. `["z"]` for `-lz`) -- `header` only has
    /// declarations, not the real machine code.
    link: []const []const u8 = &.{},
    /// The explicit allowlist of exact C function names to bind -- never
    /// inferred/enumerated, see `src/bindgen/Reflect.zig`'s own doc
    /// comment on why blind enumeration over an arbitrary header is
    /// unsafe.
    functions: []const []const u8,
    /// Non-null marks this a "zig package" entry (Stage 2.4's `-c` mode
    /// vs. Stage 2.5's `-zig` mode are mutually exclusive per entry) --
    /// the URL/path handed to `zig fetch --save=<library>`, both against
    /// this app's own natyv-core rebuild (for the real final
    /// `b.dependency(library, ...).artifact(zig_artifact)` +
    /// `linkLibrary` step) and against a throwaway scratch project `natyv
    /// bind` uses to discover the fetched package's real installed header
    /// directory (confirmed empirically: `zig fetch --save=` is a real,
    /// idempotent no-op when the same name+url is already present, so
    /// re-running this on every `natyv bind` is safe). When set,
    /// `include_dirs`/`lib_dirs`/`link` stay empty for this entry --
    /// linking happens via the fetched package's own build.zig
    /// (`linkLibrary` automatically propagates its installed headers too,
    /// confirmed against this project's own real SDL3 usage in
    /// `build.zig`/`src/c.zig`), not flags.
    zig_url: ?[]const u8 = null,
    /// Required alongside `zig_url` -- the exact `*Step.Compile` artifact
    /// name the fetched package's own build.zig exposes (e.g. `"z"` for
    /// `allyourcodebase/zlib`). No viable default guess exists for this
    /// (unlike `header`'s `<library>.h` convention) -- real Zig-ecosystem
    /// knowledge the dev must already have to consume the package at all.
    zig_artifact: ?[]const u8 = null,
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
/// written on disk. Also what the compiled guest module's own filename
/// is derived from -- see the note on `app_wasm` below.
name: []const u8 = "natyv-app",
/// The command `natyv prepare`/`natyv build` run to compile this app's own
/// guest source to wasm (e.g. `tinygo build -target wasip1
/// -buildmode=c-shared -o clay-fixture.wasm .`) -- natyv never shells out
/// to N different guest-language compilers itself (see CLAUDE.md's CLI
/// build flow section), it only spawns whatever the dev already uses.
/// Required: a real install shouldn't require remembering undocumented
/// flags to build someone else's app correctly.
wasm_compile: []const u8,
sqlite: SqliteConfig = .{},
network: NetworkConfig = .{},
widgets: WidgetsConfig = .{},
ui: UiConfig = .{},
/// Libraries `natyv bind` generates C bindings for -- see `BindingEntry`'s
/// own doc comment. Empty (the default) means no bindings for this app.
bindings: []const BindingEntry = &.{},

/// The compiled guest module's real on-disk filename, derived from
/// `name` -- `natyv prepare`/`natyv build` always compile to `<name>.wasm`
/// (a real, already-consistent convention across every existing example
/// even from back when `app_wasm` was still a distinct public field: its
/// value was always exactly this). Lives under `guest/` alongside the
/// rest of the guest source, resolved relative to the config file's own
/// directory (not the process's cwd) -- see main.zig/cli/main.zig.
pub fn wasmFilename(self: Self, allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.wasm", .{self.name});
}

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
    const parsed = try parseBytes(allocator, "{\"wasm_compile\":\"tinygo build -o app.wasm .\"}");
    defer parsed.deinit();
    try std.testing.expectEqualStrings("natyv-app", parsed.value.name);
    try std.testing.expect(!parsed.value.sqlite.enabled);
    try std.testing.expect(!parsed.value.network.enabled);
    try std.testing.expectEqualStrings("data.sqlite3", parsed.value.sqlite.filename);
    try std.testing.expect(!parsed.value.widgets.button);
    try std.testing.expectEqual(@as(?[]const u8, null), parsed.value.ui.backend);
}

test "ui.backend: clay opts an app into the natyv_clay_* host functions" {
    const allocator = std.testing.allocator;
    const parsed = try parseBytes(allocator, "{\"wasm_compile\":\"tinygo build -o app.wasm .\",\"ui\":{\"backend\":\"clay\"}}");
    defer parsed.deinit();
    try std.testing.expectEqualStrings("clay", parsed.value.ui.backend.?);
}

test "app_wasm is no longer a recognized field -- silently ignored, not required" {
    const allocator = std.testing.allocator;
    const parsed = try parseBytes(allocator, "{\"app_wasm\":\"guest/app.wasm\",\"wasm_compile\":\"tinygo build -o app.wasm .\"}");
    defer parsed.deinit();
    try std.testing.expectEqualStrings("natyv-app", parsed.value.name);
}

test "wasm_compile is required" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.MissingField, parseBytes(allocator, "{}"));
}

test "wasmFilename derives <name>.wasm" {
    const allocator = std.testing.allocator;
    const parsed = try parseBytes(allocator, "{\"name\":\"bookstore\",\"wasm_compile\":\"tinygo build -o app.wasm .\"}");
    defer parsed.deinit();
    const filename = try parsed.value.wasmFilename(allocator);
    defer allocator.free(filename);
    try std.testing.expectEqualStrings("bookstore.wasm", filename);
}

test "bindings: defaults to empty, a real entry parses with all its own fields" {
    const allocator = std.testing.allocator;
    const parsed = try parseBytes(allocator, "{\"wasm_compile\":\"tinygo build -o app.wasm .\"}");
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.value.bindings.len);

    const with_binding = try parseBytes(allocator,
        \\{
        \\  "wasm_compile": "tinygo build -o app.wasm .",
        \\  "bindings": [
        \\    { "library": "fixture", "header": "fixture.h",
        \\      "include_dirs": ["fixtures/bindgen"], "link": [],
        \\      "functions": ["fixture_create", "fixture_destroy"] }
        \\  ]
        \\}
    );
    defer with_binding.deinit();
    try std.testing.expectEqual(@as(usize, 1), with_binding.value.bindings.len);
    const entry = with_binding.value.bindings[0];
    try std.testing.expectEqualStrings("fixture", entry.library);
    try std.testing.expectEqualStrings("fixture.h", entry.header);
    try std.testing.expectEqual(@as(usize, 1), entry.include_dirs.len);
    try std.testing.expectEqualStrings("fixtures/bindgen", entry.include_dirs[0]);
    try std.testing.expectEqual(@as(usize, 2), entry.functions.len);
    try std.testing.expectEqualStrings("fixture_create", entry.functions[0]);
}

test "full config: every section populated" {
    const allocator = std.testing.allocator;
    const parsed = try parseBytes(allocator,
        \\{
        \\  "name": "bookstore",
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
