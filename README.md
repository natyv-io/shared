# natyv-io/shared

Code genuinely needed by more than one [natyv-io](https://github.com/natyv-io) repo.

Today that's just `Config` -- the `conf.natyv.json` schema and parser used by both
[natyv-io/core](https://github.com/natyv-io/core) (which loads its own bundled config at runtime) and
[natyv-io/cli](https://github.com/natyv-io/cli) (which reads config fields like `icon`/
`compile_targets` at build time). Both depend on this repo as a real Zig package rather than
duplicating the schema, so a config change only ever needs to land in one place.
