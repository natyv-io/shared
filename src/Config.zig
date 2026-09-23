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

pub const HttpConfig = struct {
    /// Exactly which hosts the guest may reach over HTTP -- the real
    /// security boundary, enforced by Extism's manifest `allowed_hosts`.
    /// Wildcards are supported by that schema. Ignored (treated as no
    /// hosts allowed) if `network.enabled` is false, regardless of this
    /// list -- so flipping `enabled` off is always the fail-safe way to
    /// cut network access entirely, not just an unenforced hint.
    allowed_hosts: []const []const u8 = &.{},
};

/// How a `tcp.allowed_sockets` entry's connection is secured. Chosen by the
/// dev per endpoint, never by the guest at `tcp_connect` time -- a guest
/// can't request a looser mode than the one configured here. `.implicit`
/// handshakes TLS immediately on connect (e.g. IMAPS on 993); `.starttls`
/// connects plaintext and only upgrades once the guest explicitly asks
/// (e.g. SMTP submission on 587, after the guest itself sends `STARTTLS`
/// and reads the server's plaintext OK); `.none` never upgrades at all.
pub const TlsMode = enum {
    none,
    implicit,
    starttls,
};

/// How `natyv build` compiles natyv-core itself for this app -- maps
/// one-to-one onto Zig's own real `std.builtin.OptimizeMode` choices,
/// just spelled out in natyv's own conf.natyv.json vocabulary rather than
/// Zig's, matching `TlsMode` above's own precedent of a plain enum parsed
/// directly from a JSON string. `.debug` (the field's own default, see
/// `build_mode` below) preserves `natyv build`'s original behavior
/// exactly -- full debug symbols, no optimization, by far the largest and
/// slowest-running binary, but the fastest to iterate on. **Real,
/// measured difference, confirmed via a live A/B rebuild of the
/// mail-natyv benchmark app (2026-09-03)**: `.release_small` cut that
/// same app's real bundled size from 84MB to 27MB (a real ~3x reduction,
/// not a rough estimate) and *lowered* idle RSS too (roughly 54-56MB vs
/// 70-100MB) -- any app meant for real distribution should set this to a
/// release mode, not ship on the default. `.release_small`/
/// `.release_fast`/`.release_safe` are Zig's own real remaining three
/// modes, offered as distinct choices (not collapsed into one generic
/// "release") since size-vs-speed is a real, per-app tradeoff natyv
/// shouldn't silently pick for a dev -- natyv's own positioning leans
/// toward `.release_small` (see core's CLAUDE.md "leaner than Electron on
/// memory"), but `.release_fast` is the more conventional default for a
/// CPU-bound app that would rather trade disk size for raw speed.
pub const BuildMode = enum {
    debug,
    release_fast,
    release_small,
    release_safe,

    /// The real `-Doptimize=<...>` flag `Bundle.zig` passes straight
    /// through to `zig build` -- kept here, next to the enum it derives
    /// from, rather than as a lookup table living in `cli` -- so this
    /// mapping only ever has one real home to go stale in.
    pub fn optimizeFlag(self: BuildMode) []const u8 {
        return switch (self) {
            .debug => "-Doptimize=Debug",
            .release_fast => "-Doptimize=ReleaseFast",
            .release_small => "-Doptimize=ReleaseSmall",
            .release_safe => "-Doptimize=ReleaseSafe",
        };
    }
};

/// One endpoint a guest may open a raw TCP socket to -- see
/// `natyv-tcp-tls-host-function` memory for the full design. Real
/// enforcement happens at `tcp_connect` time: any host:port the guest
/// requests that isn't an exact match here is rejected.
pub const AllowedSocket = struct {
    host: []const u8,
    port: u16,
    tls: TlsMode = .none,
    /// How long `tcp_connect` waits before giving up on this endpoint
    /// specifically, overriding the built-in default
    /// (`capabilities/Tcp.zig`'s `connect_timeout_secs`) -- e.g. a slower
    /// legacy server might need more than the default allows. `null` (the
    /// default) means "use the built-in default."
    timeout_secs: ?i64 = null,
    /// Path to a PEM file (relative to this config file's own directory,
    /// same convention as `icon`), trusted as the *only* CA for this one
    /// endpoint instead of the bundled Mozilla CA store (`Tls.zig`'s own
    /// default) -- for a dev's private/internal CA or self-hosted server.
    /// Replaces the default trust set for this endpoint entirely rather
    /// than adding to it, so a locked-down private connection doesn't also
    /// stay implicitly trusting every public CA. `null` (the default) uses
    /// the bundled store. Staged and embedded at real `natyv build` time
    /// (see `natyv-tcp-tls-host-function` memory) -- resolved from a live
    /// disk read only in local dev iteration (`natyv build` not yet run).
    ca_cert_path: ?[]const u8 = null,
};

pub const TcpConfig = struct {
    /// Ignored (treated as no sockets allowed) if `network.enabled` is
    /// false, same fail-safe posture as `HttpConfig.allowed_hosts`.
    allowed_sockets: []const AllowedSocket = &.{},
};

pub const NetworkConfig = struct {
    enabled: bool = false,
    http: HttpConfig = .{},
    tcp: TcpConfig = .{},
};

/// Same posture as SqliteConfig/NetworkConfig -- a `texture` fill in the
/// stylesheet is a real error at `natyv prepare` time unless this is
/// explicitly enabled, matching the styling system's own "closed
/// vocabulary, clear errors" convention rather than silently ignoring it.
pub const ImagesConfig = struct {
    enabled: bool = false,
};

/// Controls the memory-reclamation recycle mechanism's real trigger --
/// see `project_natyv_instance_recycling_idea` memory for the full design.
/// `null` (the default) disables automatic RSS-based recycling entirely,
/// same fail-safe-off posture as every other capability here -- a dev has
/// to explicitly opt in, since a recycle force-closes every open TCP
/// connection and isn't free (a real, measured ~30ms). This is also a
/// second, independent gate on top of `can_recycle` (the app implementing
/// both `natyv_checkpoint`/`natyv_resume`) -- an app that implements those
/// exports for some other reason doesn't get automatic recycling just for
/// that; it has to also set a threshold here.
pub const MemoryConfig = struct {
    /// Real process RSS, in MB -- once a post-dispatch check sees the
    /// process at or above this, the host recycles the guest instance
    /// before the next dispatch. Compared against whole-process RSS (the
    /// same number `ps`/Activity Monitor report, and the same measurement
    /// this project's own recycle benchmarking already uses), not an
    /// estimate of the guest's own linear memory alone -- Extism/Wasmtime
    /// doesn't expose that as a separate, cheaper number, and whole-process
    /// RSS is what a dev actually cares about bounding regardless.
    recycle_threshold_mb: ?u32 = null,
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
    /// Non-null marks this a "locally vendored" entry (Stage 2.6's `-c=`
    /// URL vendoring, mutually exclusive with `zig_url` -- a `-c=<url>`
    /// vs `-zig=<url>` choice at `natyv get` time) -- the raw C source
    /// URL/path handed to `zig fetch --save=<library>` (no build.zig
    /// assumed at all, unlike `zig_url`; see `src/cli/Vendor.zig`'s own
    /// doc comment for why `zig fetch` still works fine for a plain
    /// source tarball with no Zig package structure). The object code
    /// this produces becomes part of the same build directly, so
    /// `include_dirs`/`lib_dirs`/`link` are used differently here than
    /// elsewhere: `include_dirs` still gets the vendored source's own
    /// directory appended (so its `.c` files' own local `#include`s
    /// resolve) but `link`/`lib_dirs` normally stay empty unless the
    /// vendored library itself needs an additional external system
    /// library (rare, but not assumed impossible).
    vendor_url: ?[]const u8 = null,
    /// Tier 1 (the default, used when `vendor_c_build` is unset): real,
    /// relative-to-the-vendored-source-root `.c` file paths to compile
    /// directly -- computed once by `natyv get`'s own real fetch+walk (a
    /// first-cut heuristic: every real `.c` file found, skipping any path
    /// with a `test`/`tests`/`example`/`examples` component) and
    /// persisted here so a dev can hand-curate it afterward, exactly
    /// mirroring this project's own real, hand-pruned FreeType vendoring
    /// in `build.zig` (a library whose optional features are gated by
    /// build-time config knobs may need the same kind of manual pruning
    /// to avoid pulling in an unwanted transitive dependency -- not
    /// solved generically here either, matching that same precedent).
    vendor_files: []const []const u8 = &.{},
    /// Tier 2, opt-in (mirrors `wasm_compile`'s shape exactly): when set,
    /// `natyv bind` runs this exact shell command inside the freshly-
    /// fetched vendor source directory instead of compiling
    /// `vendor_files` itself -- the dev is then responsible for
    /// `include_dirs`/`lib_dirs`/`link` describing whatever that command
    /// produced (interpreted relative to the vendor source root in this
    /// mode, unlike every other mode's cwd-relative-or-absolute paths).
    vendor_c_build: ?[]const u8 = null,
};

pub const UiConfig = struct {
    /// `null` (the default) means the app uses the plain, absolute-pixel
    /// `natyv_create_*` widget functions and gets none of the
    /// `natyv_clay_*` ones -- keeps bundles small for apps that don't need
    /// layout, same enforcement story as every other capability here.
    /// `"clay"` is the only recognized value today; `"yoga"` is reserved
    /// for when that backend actually gets built (see project memory).
    backend: ?[]const u8 = null,
    /// The window's own background fill, as `#RRGGBB` or `#RRGGBBAA`.
    /// `null` (the default) keeps natyv's built-in dark ground, `#18181C`.
    ///
    /// Window-level rather than an `.ntss` token on purpose: this is the
    /// color SDL clears the renderer to before any widget draws at all, so
    /// it belongs to the window, not to any element in the tree. `.ntss`'s
    /// own `backgroundColor` stays per-element and is unaffected.
    ///
    /// Parse it with `parseHexRgba` -- a malformed value is a real startup
    /// error, not a silent fallback, matching the stylesheet resolver's own
    /// posture that a typo should be caught before it ever ships.
    background_color: ?[]const u8 = null,
    /// The startup window's size in pixels. `null` (the default) uses
    /// natyv's own 900x700.
    ///
    /// Only the startup window: a window the guest opens itself via
    /// `natyv_clay_create_window` passes its own explicit size, and is
    /// deliberately never overridden by this -- the guest asked for those
    /// dimensions on purpose.
    width: ?u16 = null,
    height: ?u16 = null,
};

/// A plain 8-bit-per-channel color. Deliberately not the styling
/// `Resolver.Color` (normalized f32): that type lives in the `styling`
/// module, which `natyv-core` doesn't import -- core only ever pulls in
/// `Config` (see natyv-io/core's build.zig), and adding a whole module
/// dependency for one color parse would be the wrong trade.
pub const Rgba = struct { r: u8, g: u8, b: u8, a: u8 };

/// Parses `#RRGGBB` / `#RRGGBBAA`, returning null on anything malformed.
///
/// **Deliberately the same grammar** `styling/Resolver.zig`'s own
/// `parseHexColor` accepts, so a color written in `conf.natyv.json` and the
/// same color written in an `.ntss` file never disagree. That is two
/// parsers for one syntax; they are kept in sync by hand today. If a third
/// consumer ever appears, extract a shared one rather than adding another.
pub fn parseHexRgba(s: []const u8) ?Rgba {
    if (s.len != 7 and s.len != 9) return null;
    if (s[0] != '#') return null;
    const r = std.fmt.parseInt(u8, s[1..3], 16) catch return null;
    const g = std.fmt.parseInt(u8, s[3..5], 16) catch return null;
    const b = std.fmt.parseInt(u8, s[5..7], 16) catch return null;
    const a = if (s.len == 9) std.fmt.parseInt(u8, s[7..9], 16) catch return null else 255;
    return .{ .r = r, .g = g, .b = b, .a = a };
}

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
images: ImagesConfig = .{},
memory: MemoryConfig = .{},
ui: UiConfig = .{},
/// Where the guest's own `pdk.Log(...)` calls (via Extism's built-in
/// `extism:host/env log_*` imports -- no natyv-core host function needed,
/// every plugin gets these for free) actually go. `null` (the default)
/// means logging is fully disabled -- natyv-core never calls
/// `extism_log_custom` at all, so a guest's log calls are silently
/// dropped by Extism itself rather than natyv-core doing any filtering of
/// its own. `"stdout"`/`"stderr"` write to the process's own standard
/// streams; any other value is treated as a filename, resolved via
/// `SDL_GetPrefPath` the same way `sqlite.filename` already is (real,
/// per-app, per-OS-conventional storage, not a bare cwd-relative path).
/// Which level a given call logs at is a guest-code decision (see
/// `sdk/go`'s own `Info`/`Warn`/etc. wrappers), not something this field
/// controls -- natyv-core always subscribes to every level and lets the
/// drain handler decide what (if anything) to do with each line.
logging: ?[]const u8 = null,
/// Libraries `natyv bind` generates C bindings for -- see `BindingEntry`'s
/// own doc comment. Empty (the default) means no bindings for this app.
bindings: []const BindingEntry = &.{},
/// Real macOS `.app` bundle identifier (`CFBundleIdentifier`, e.g.
/// `"com.example.myapp"`) -- Apple's own tooling expects a real
/// reverse-DNS-shaped value, but there's no way to derive one from `name`
/// alone the way `CFBundleName`/the window title/the wasm filename all
/// already are. `null` (the default) synthesizes `dev.natyv.<name>` at
/// bundle time (`effectiveBundleId` below) -- good enough to build/run/
/// debug locally; a dev planning to actually distribute/notarize the app
/// should set a real one they own.
bundle_id: ?[]const u8 = null,
/// Path to a single high-resolution (1024x1024 recommended) PNG, relative
/// to this config file's own directory -- `natyv build` generates the
/// full macOS `.iconset` (every required size) from it via `sips`, then
/// packs a real `.icns` via `iconutil` (see `Bundle.zig`). `null` (the
/// default) means the bundled app gets macOS's own generic app icon
/// rather than a custom one. Deliberately not gated behind a capability
/// flag the way `images`/texture-fill is -- this is build-time bundling
/// metadata, not a runtime host feature.
icon: ?[]const u8 = null,

/// Which OSes `natyv build` produces real binaries for, using natyv's own
/// friendly target names (see `cli/CompileTargets.zig`), not raw Zig
/// target triples -- hides an implementation detail (e.g. `windows-gnu`
/// vs `windows-msvc`) devs shouldn't need to know, and lets natyv remap
/// the underlying triple later without breaking existing configs.
/// Empty (the default) means "build for whatever OS `natyv build` itself
/// is running on," exactly today's existing behavior -- unchanged for any
/// app that never sets this. Only names natyv has actually verified
/// *running* (not just compiling) are accepted -- see
/// `CompileTargets.resolve`'s own doc comment for which those are today.
compile_targets: []const []const u8 = &.{},

/// Only meaningful when `compile_targets` includes a Linux target.
/// `"appimage"` wraps the built binary into a real, distributable
/// `.AppImage` (see `cli/PackageAppImage.zig` and the
/// `natyv-linux-appimage-packaging` memory for the full design/proof).
/// `null` (the default) ships the plain flat ELF binary, matching
/// today's existing behavior -- deliberately opt-in rather than
/// automatic, since a real AppImage is a meaningfully heavier artifact
/// (a real runtime binary gets concatenated on) that a dev doing quick
/// local iteration usually doesn't want on every single build.
linux_package: ?[]const u8 = null,

/// How `natyv build` compiles natyv-core itself for this app -- see
/// `BuildMode`'s own doc comment above for the real, measured reason this
/// exists. `.debug` is the default, preserving `natyv build`'s original
/// behavior exactly (unset `-Doptimize` means Zig's own implicit Debug
/// default).
build_mode: BuildMode = .debug,

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

/// `bundle_id` if the dev set one, otherwise a synthesized
/// `dev.natyv.<name>` default -- see `bundle_id`'s own doc comment.
/// Always returns a freshly allocated string either way, so callers have
/// one consistent ownership story regardless of which branch was taken.
pub fn effectiveBundleId(self: Self, allocator: std.mem.Allocator) ![]u8 {
    if (self.bundle_id) |id| return allocator.dupe(u8, id);
    return std.fmt.allocPrint(allocator, "dev.natyv.{s}", .{self.name});
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
    try std.testing.expectEqual(@as(?[]const u8, null), parsed.value.ui.backend);
}

test "ui.backend: clay opts an app into the natyv_clay_* host functions" {
    const allocator = std.testing.allocator;
    const parsed = try parseBytes(allocator, "{\"wasm_compile\":\"tinygo build -o app.wasm .\",\"ui\":{\"backend\":\"clay\"}}");
    defer parsed.deinit();
    try std.testing.expectEqualStrings("clay", parsed.value.ui.backend.?);
}

test "ui.background_color: absent by default, parsed when present" {
    const allocator = std.testing.allocator;
    const bare = try parseBytes(allocator, "{\"wasm_compile\":\"tinygo build -o app.wasm .\"}");
    defer bare.deinit();
    try std.testing.expectEqual(@as(?[]const u8, null), bare.value.ui.background_color);

    const set = try parseBytes(allocator, "{\"wasm_compile\":\"x\",\"ui\":{\"background_color\":\"#101014\"}}");
    defer set.deinit();
    try std.testing.expectEqualStrings("#101014", set.value.ui.background_color.?);
}

test "ui.width/height: absent by default, parsed when present" {
    const allocator = std.testing.allocator;
    const bare = try parseBytes(allocator, "{\"wasm_compile\":\"x\"}");
    defer bare.deinit();
    try std.testing.expectEqual(@as(?u16, null), bare.value.ui.width);
    try std.testing.expectEqual(@as(?u16, null), bare.value.ui.height);

    const set = try parseBytes(allocator, "{\"wasm_compile\":\"x\",\"ui\":{\"width\":1280,\"height\":800}}");
    defer set.deinit();
    try std.testing.expectEqual(@as(u16, 1280), set.value.ui.width.?);
    try std.testing.expectEqual(@as(u16, 800), set.value.ui.height.?);
}

test "parseHexRgba accepts #RRGGBB and #RRGGBBAA, rejects everything else" {
    const opaque_color = parseHexRgba("#18181C").?;
    try std.testing.expectEqual(@as(u8, 0x18), opaque_color.r);
    try std.testing.expectEqual(@as(u8, 0x18), opaque_color.g);
    try std.testing.expectEqual(@as(u8, 0x1C), opaque_color.b);
    try std.testing.expectEqual(@as(u8, 255), opaque_color.a);

    const with_alpha = parseHexRgba("#18181C80").?;
    try std.testing.expectEqual(@as(u8, 0x80), with_alpha.a);

    // The real failure modes: no hash, wrong length, non-hex digits.
    try std.testing.expect(parseHexRgba("18181C") == null);
    try std.testing.expect(parseHexRgba("#18181") == null);
    try std.testing.expect(parseHexRgba("#18181CC") == null);
    try std.testing.expect(parseHexRgba("#GGGGGG") == null);
    try std.testing.expect(parseHexRgba("") == null);
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

test "logging: defaults to null (disabled), stdout/stderr/a filename all round-trip" {
    const allocator = std.testing.allocator;
    const defaults = try parseBytes(allocator, "{\"wasm_compile\":\"tinygo build -o app.wasm .\"}");
    defer defaults.deinit();
    try std.testing.expect(defaults.value.logging == null);

    const stdout = try parseBytes(allocator,
        \\{"wasm_compile":"tinygo build -o app.wasm .","logging":"stdout"}
    );
    defer stdout.deinit();
    try std.testing.expectEqualStrings("stdout", stdout.value.logging.?);

    const file = try parseBytes(allocator,
        \\{"wasm_compile":"tinygo build -o app.wasm .","logging":"app.log"}
    );
    defer file.deinit();
    try std.testing.expectEqualStrings("app.log", file.value.logging.?);
}

test "build_mode: defaults to .debug, each real Zig optimize mode round-trips with the right flag" {
    const allocator = std.testing.allocator;
    const defaults = try parseBytes(allocator, "{\"wasm_compile\":\"tinygo build -o app.wasm .\"}");
    defer defaults.deinit();
    try std.testing.expectEqual(BuildMode.debug, defaults.value.build_mode);
    try std.testing.expectEqualStrings("-Doptimize=Debug", defaults.value.build_mode.optimizeFlag());

    const cases = [_]struct { json: []const u8, mode: BuildMode, flag: []const u8 }{
        .{ .json = "release_fast", .mode = .release_fast, .flag = "-Doptimize=ReleaseFast" },
        .{ .json = "release_small", .mode = .release_small, .flag = "-Doptimize=ReleaseSmall" },
        .{ .json = "release_safe", .mode = .release_safe, .flag = "-Doptimize=ReleaseSafe" },
    };
    for (cases) |case| {
        const buf = try std.fmt.allocPrint(allocator, "{{\"wasm_compile\":\"tinygo build -o app.wasm .\",\"build_mode\":\"{s}\"}}", .{case.json});
        defer allocator.free(buf);
        const parsed = try parseBytes(allocator, buf);
        defer parsed.deinit();
        try std.testing.expectEqual(case.mode, parsed.value.build_mode);
        try std.testing.expectEqualStrings(case.flag, parsed.value.build_mode.optimizeFlag());
    }
}

test "bundle_id/icon: default to null, a real value round-trips" {
    const allocator = std.testing.allocator;
    const defaults = try parseBytes(allocator, "{\"wasm_compile\":\"tinygo build -o app.wasm .\"}");
    defer defaults.deinit();
    try std.testing.expect(defaults.value.bundle_id == null);
    try std.testing.expect(defaults.value.icon == null);

    const with_both = try parseBytes(allocator,
        \\{"wasm_compile":"tinygo build -o app.wasm .","bundle_id":"com.example.myapp","icon":"icon.png"}
    );
    defer with_both.deinit();
    try std.testing.expectEqualStrings("com.example.myapp", with_both.value.bundle_id.?);
    try std.testing.expectEqualStrings("icon.png", with_both.value.icon.?);
}

test "effectiveBundleId: synthesizes dev.natyv.<name> when unset, uses the real value otherwise" {
    const allocator = std.testing.allocator;
    const defaults = try parseBytes(allocator, "{\"name\":\"bookstore\",\"wasm_compile\":\"tinygo build -o app.wasm .\"}");
    defer defaults.deinit();
    const synthesized = try defaults.value.effectiveBundleId(allocator);
    defer allocator.free(synthesized);
    try std.testing.expectEqualStrings("dev.natyv.bookstore", synthesized);

    const explicit = try parseBytes(allocator,
        \\{"name":"bookstore","wasm_compile":"tinygo build -o app.wasm .","bundle_id":"com.example.bookstore"}
    );
    defer explicit.deinit();
    const real = try explicit.value.effectiveBundleId(allocator);
    defer allocator.free(real);
    try std.testing.expectEqualStrings("com.example.bookstore", real);
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
        \\  "network": {
        \\    "enabled": true,
        \\    "http": {"allowed_hosts": ["www.google.com"]},
        \\    "tcp": {"allowed_sockets": [{"host": "imap.gmail.com", "port": 993, "tls": "implicit"}]}
        \\  }
        \\}
    );
    defer parsed.deinit();
    try std.testing.expectEqualStrings("bookstore", parsed.value.name);
    try std.testing.expect(parsed.value.sqlite.enabled);
    try std.testing.expectEqualStrings("books.sqlite3", parsed.value.sqlite.filename);
    try std.testing.expect(parsed.value.network.enabled);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.network.http.allowed_hosts.len);
    try std.testing.expectEqualStrings("www.google.com", parsed.value.network.http.allowed_hosts[0]);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.network.tcp.allowed_sockets.len);
    const socket = parsed.value.network.tcp.allowed_sockets[0];
    try std.testing.expectEqualStrings("imap.gmail.com", socket.host);
    try std.testing.expectEqual(@as(u16, 993), socket.port);
    try std.testing.expectEqual(TlsMode.implicit, socket.tls);
}

test "tcp.allowed_sockets: defaults to empty, tls mode defaults to none" {
    const allocator = std.testing.allocator;
    const parsed = try parseBytes(allocator,
        \\{"wasm_compile":"tinygo build -o app.wasm .","network":{"enabled":true,"tcp":{"allowed_sockets":[{"host":"smtp.gmail.com","port":587,"tls":"starttls"},{"host":"example.com","port":80}]}}}
    );
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.network.tcp.allowed_sockets.len);
    try std.testing.expectEqual(TlsMode.starttls, parsed.value.network.tcp.allowed_sockets[0].tls);
    try std.testing.expectEqual(TlsMode.none, parsed.value.network.tcp.allowed_sockets[1].tls);

    const defaults = try parseBytes(allocator, "{\"wasm_compile\":\"tinygo build -o app.wasm .\"}");
    defer defaults.deinit();
    try std.testing.expectEqual(@as(usize, 0), defaults.value.network.tcp.allowed_sockets.len);
    try std.testing.expectEqual(@as(usize, 0), defaults.value.network.http.allowed_hosts.len);
}

test "tcp.allowed_sockets: timeout_secs defaults to null, an explicit per-endpoint override round-trips" {
    const allocator = std.testing.allocator;
    const parsed = try parseBytes(allocator,
        \\{"wasm_compile":"tinygo build -o app.wasm .","network":{"enabled":true,"tcp":{"allowed_sockets":[
        \\  {"host":"slow.example.com","port":993,"tls":"implicit","timeout_secs":30},
        \\  {"host":"imap.gmail.com","port":993,"tls":"implicit"}
        \\]}}}
    );
    defer parsed.deinit();
    try std.testing.expectEqual(@as(?i64, 30), parsed.value.network.tcp.allowed_sockets[0].timeout_secs);
    try std.testing.expectEqual(@as(?i64, null), parsed.value.network.tcp.allowed_sockets[1].timeout_secs);
}

test "tcp.allowed_sockets: ca_cert_path defaults to null, an explicit path round-trips" {
    const allocator = std.testing.allocator;
    const parsed = try parseBytes(allocator,
        \\{"wasm_compile":"tinygo build -o app.wasm .","network":{"enabled":true,"tcp":{"allowed_sockets":[
        \\  {"host":"internal.example.com","port":993,"tls":"implicit","ca_cert_path":"certs/internal-ca.pem"},
        \\  {"host":"imap.gmail.com","port":993,"tls":"implicit"}
        \\]}}}
    );
    defer parsed.deinit();
    try std.testing.expectEqualStrings("certs/internal-ca.pem", parsed.value.network.tcp.allowed_sockets[0].ca_cert_path.?);
    try std.testing.expectEqual(@as(?[]const u8, null), parsed.value.network.tcp.allowed_sockets[1].ca_cert_path);
}

test "widgets is no longer a recognized field -- silently ignored, every widget kind just works" {
    const allocator = std.testing.allocator;
    const parsed = try parseBytes(allocator, "{\"wasm_compile\":\"tinygo build -o app.wasm .\",\"widgets\":{\"button\":false,\"label\":false}}");
    defer parsed.deinit();
    try std.testing.expectEqualStrings("natyv-app", parsed.value.name);
}

test "compile_targets/linux_package: default to empty/null, an explicit value round-trips" {
    const allocator = std.testing.allocator;
    const defaults = try parseBytes(allocator, "{\"wasm_compile\":\"tinygo build -o app.wasm .\"}");
    defer defaults.deinit();
    try std.testing.expectEqual(@as(usize, 0), defaults.value.compile_targets.len);
    try std.testing.expect(defaults.value.linux_package == null);

    const with_both = try parseBytes(allocator,
        \\{"wasm_compile":"tinygo build -o app.wasm .","compile_targets":["macos-arm64","linux-arm64"],"linux_package":"appimage"}
    );
    defer with_both.deinit();
    try std.testing.expectEqual(@as(usize, 2), with_both.value.compile_targets.len);
    try std.testing.expectEqualStrings("macos-arm64", with_both.value.compile_targets[0]);
    try std.testing.expectEqualStrings("linux-arm64", with_both.value.compile_targets[1]);
    try std.testing.expectEqualStrings("appimage", with_both.value.linux_package.?);
}

test "memory.recycle_threshold_mb: defaults to null (recycling disabled), an explicit value round-trips" {
    const allocator = std.testing.allocator;
    const defaults = try parseBytes(allocator, "{\"wasm_compile\":\"tinygo build -o app.wasm .\"}");
    defer defaults.deinit();
    try std.testing.expectEqual(@as(?u32, null), defaults.value.memory.recycle_threshold_mb);

    const with_threshold = try parseBytes(allocator,
        \\{"wasm_compile":"tinygo build -o app.wasm .","memory":{"recycle_threshold_mb":200}}
    );
    defer with_threshold.deinit();
    try std.testing.expectEqual(@as(?u32, 200), with_threshold.value.memory.recycle_threshold_mb);
}
