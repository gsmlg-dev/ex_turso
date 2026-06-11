# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

ExTurso is an Elixir library wrapping the `turso` Rust crate (v0.5, SQLite-compatible) via Rustler NIFs, exposed through a `DBConnection` pool. It supports local file databases, in-memory databases (`":memory:"`), and Turso Cloud sync via embedded replicas. A working Rust toolchain (`cargo`) is required — `mix compile` builds the NIF.

## Commands

```sh
mix deps.get                      # fetch deps
mix compile --warnings-as-errors  # compiles Elixir + Rust NIF (CI enforces no warnings)
mix test                          # run all tests
mix test test/ex_turso_test.exs:42   # run a single test by line
mix format --check-formatted      # Elixir formatting (CI check)

# Rust checks (CI runs all three):
cargo fmt --manifest-path native/ex_turso/Cargo.toml --check
cargo clippy --manifest-path native/ex_turso/Cargo.toml --locked --all-targets --all-features -- -D warnings
cargo build --manifest-path native/ex_turso/Cargo.toml --locked
```

Tests open an in-memory database with `pool_size: 1` per test (data must stay on one connection handle since each pooled connection gets its own `:memory:` database).

## Architecture

The library is a four-layer stack; a query crosses all of them:

1. **`ExTurso`** (lib/ex_turso.ex) — public API: `start_link/1`, `child_spec/1`, `query/4`, `execute/4`, `sync/2`. Each call builds an `%ExTurso.Query{statement, command}` and runs it through `DBConnection.execute/4`.
2. **`ExTurso.Query`** — struct implementing the `DBConnection.Query` protocol. The `command` field (`:query` | `:execute` | `:sync`) is what routes behavior, not the SQL text. `ExTurso.sync/2` is implemented as a fake `"SYNC"` statement with `command: :sync` so it flows through the normal DBConnection pipeline.
3. **`ExTurso.Connection`** — `DBConnection` behaviour implementation. State holds NIF resource references: `db`, `conn`, `sync_db` (nil unless cloud-synced), and `status` (`:idle` | `:transaction`). `handle_execute/4` pattern-matches on the query's `command`. Transactions are plain `BEGIN`/`COMMIT`/`ROLLBACK` via the execute NIF. Error routing: transaction-control failures and statement errors with code `:io`/`:corrupt` return `{:disconnect, ...}` (connection is replaced by the pool); all other statement errors return `{:error, ...}` (connection survives). `ping/1` runs `SELECT 1`. `:auth_token` may be a string or a zero-arity function (resolved in `connect/1`). Prepare/close are no-ops (no server-side prepared statements); cursors are unsupported.
4. **`ExTurso.Native`** (lib/ex_turso/native.ex ↔ native/ex_turso/src/lib.rs) — Rustler NIF stubs replaced at load time. All NIFs run on dirty IO schedulers and return `{:error, {code_atom, reason_string}}` on failure, where the code (`:busy`, `:constraint`, `:io`, `:corrupt`, `:misuse`, `:invalid_param`, `:error`) is classified from the `turso::Error` variant in `classify/1`; the Elixir layer wraps these into `%ExTurso.Error{code, message}`. The Rust side drives turso's async API from a single global Tokio runtime (`RT.block_on`); database/connection handles are `ResourceArc<Mutex<...>>` so their lifetimes are tied to the BEAM GC.

### Cloud sync

`connect/1` in `ExTurso.Connection` branches on opts: `:remote_url` + `:auth_token` together open a synced replica via `open_sync`/`connect_sync` NIFs (turso crate's `sync` feature); providing only one of them is an error. Sync is rejected inside a transaction and on non-synced databases.

### Value mapping (Rust side)

Elixir → SQL params: integers (i64 range) → Integer, floats → Real, UTF-8 binaries → Text, other binaries → Blob, `nil` → Null, `true`/`false` → 1/0. Any other term (atoms, lists, maps, bignums) is rejected with an `:invalid_param` error — never silently coerced. Result rows come back as a list of maps keyed by column name; `execute` returns the affected-row count in `Result.num_rows`.

## Other Docs

- `AGENTS.md` — actor-model specification of the supervision/process architecture (pool, connection workers, NIF gateway, failure modes).
- `docs/superpowers/plans/` — implementation plans with checkbox task tracking.
