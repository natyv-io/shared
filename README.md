# natyv-io/shared

A generic toolbox of code genuinely needed by more than one [natyv-io](https://github.com/natyv-io)
repo — not scoped to any one usecase. Every module here is exposed as a plain Zig module and consumed
via `b.dependency("shared", ...).module("...")`, the same mechanism already used for every other
external dependency in the natyv-io repos.

Currently holds:

- **`Config`** — the `conf.natyv.json` schema and parser, used by both
  [natyv-io/core](https://github.com/natyv-io/core) (which loads its own bundled config at runtime) and
  [natyv-io/cli](https://github.com/natyv-io/cli) (which reads config fields like `icon`/
  `compile_targets` at build time). Both depend on this repo rather than duplicating the schema, so a
  config change only ever needs to land in one place.
- **`Parser` / `Expose` / `Codegen` / `Resolver` / `Stylesheet`** — the `.ntx` markup transpiler core,
  moved here from `natyv-io/cli` so it can be shared with
  [natyv-io/ntx-lsp](https://github.com/natyv-io/ntx-lsp) too (the LSP server re-runs the same real
  transpile per request). `Codegen` also carries `PositionMap.zig` as a plain sibling file, not a
  separate module.
