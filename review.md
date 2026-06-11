# ExTurso Repository Review

Review date: 2026-06-11, at commit `7e73068` (branch `main`).

Scope: full repo — `lib/`, `native/ex_turso/src/lib.rs`, `test/`, `mix.exs`, CI workflows, README/AGENTS.md.

Overall: the codebase is small, clean, and well-layered (public API → Query protocol → DBConnection impl → NIF). Most findings below are footguns, doc drift, and hardening — not structural problems.

---

## 1. Code Quality Issues

### 1.1 `term_to_value` silently coerces unsupported terms to `NULL` — **High**

**Issue:** Any Elixir term the Rust decoder doesn't recognize becomes SQL `NULL` with no error. This silently corrupts data for common inputs:

- `true` / `false` (atoms) → `NULL` instead of `1`/`0`
- integers outside i64 range (Elixir bignums) → `NULL`
- atoms, lists, maps, `Decimal`, `Date`/`DateTime` structs → `NULL`

**Current code** (`native/ex_turso/src/lib.rs:89-101`):

```rust
fn term_to_value(term: &Term) -> Value {
    if let Ok(i) = term.decode::<i64>() {
        Value::Integer(i)
    } else if let Ok(f) = term.decode::<f64>() {
        Value::Real(f)
    } else if let Ok(s) = term.decode::<String>() {
        Value::Text(s)
    } else if let Ok(bin) = term.decode::<rustler::Binary>() {
        Value::Blob(bin.as_slice().to_vec())
    } else {
        Value::Null
    }
}
```

**Proposed solution:** Return `Result<Value, String>` and make the `query`/`execute` NIFs fail with a clear message (`"unsupported parameter type at index 2"`). Explicitly map `true`/`false` to `1`/`0` and `nil` to `Null` before the fallthrough becomes an error. This turns silent data corruption into an immediate, debuggable error.

**Priority:** High &nbsp;|&nbsp; **Effort:** Small (~1h, Rust change + tests)

### 1.2 Duplicated transaction handlers — **Low**

**Issue:** `handle_begin/2`, `handle_commit/2`, `handle_rollback/2` in `lib/ex_turso/connection.ex:74-95` are three copies of the same pattern (execute SQL, set status, disconnect on error).

**Proposed solution:** One private helper:

```elixir
defp transaction_call(sql, new_status, %__MODULE__{conn: conn} = state) do
  case Native.execute(conn, sql, []) do
    {:ok, _} -> {:ok, %Result{}, %{state | status: new_status}}
    {:error, reason} -> {:disconnect, %Error{message: reason}, state}
  end
end
```

**Priority:** Low &nbsp;|&nbsp; **Effort:** Trivial (~15min)

### 1.3 `sync_db` duplicates `db` in connection state — **Low**

**Issue:** In `lib/ex_turso/connection.ex:51`, `sync_db` is either `nil` or the exact same reference as `db`. Two fields encoding one bit of information.

**Current code:**

```elixir
{:ok, %__MODULE__{db: db, conn: conn, sync_db: if(is_sync, do: db, else: nil)}}
```

**Proposed solution:** Replace `sync_db` with `mode: :local | :sync` (or `sync?: boolean`) and use `state.db` in the sync handler. Slightly less state to keep consistent.

**Priority:** Low &nbsp;|&nbsp; **Effort:** Trivial (~15min)

### 1.4 Mutex guard held across `block_on` in NIFs — **Low (informational)**

**Issue:** `query` and `execute` (`lib.rs:189-220`) acquire the `std::sync::Mutex` guard and hold it across `RT.block_on(...)`. This works today because each `ExTurso.Connection` process owns its `conn` reference exclusively, so there is no contention. But it is a latent deadlock/blocking hazard if any future code path shares a `ConnResource` between processes or NIF calls.

**Proposed solution:** No change required now; add a comment documenting the single-owner invariant, or clone the handle out of the lock before `block_on` as `connect_sync`/`sync` already do.

**Priority:** Low &nbsp;|&nbsp; **Effort:** Trivial

---

## 2. Performance Optimizations

### 2.1 Rows returned as list-of-maps with per-row key copies — **Medium**

**Issue:** The `query` NIF (`lib.rs:191-208`) builds a `HashMap<String, SqlValue>` per row, cloning every column name for every row (`map.insert(name.clone(), ...)`). For a 100k-row × 10-column result, that's 1M string allocations on the Rust side, plus 100k Erlang maps. It also makes `SELECT a, b` row order unrecoverable.

**Current code:**

```rust
let mut map = HashMap::with_capacity(columns.len());
for (idx, name) in columns.iter().enumerate() {
    let value = row.get_value(idx).map_err(|e| e.to_string())?;
    map.insert(name.clone(), SqlValue::from(value));
}
```

**Proposed solution:** Return `{:ok, columns, rows}` where `rows` is a list of lists, and add `columns: [String.t()]` to `%ExTurso.Result{}` (the pattern used by Postgrex/Exqlite). Keep the maps API as a convenience (`Result.rows_as_maps/1` or build maps in `DBConnection.Query.decode/3`) so callers choose the cost. This also preserves column order and duplicate column names, which the current map shape silently loses.

**Priority:** Medium &nbsp;|&nbsp; **Effort:** Medium (~half day; touches NIF, Result, Connection, tests, README)

### 2.2 No prepared-statement caching — **Medium**

**Issue:** `handle_prepare/3` is a no-op (`connection.ex:138`), so every call re-parses SQL inside turso. The turso crate exposes `Connection::prepare`; hot queries (e.g. the same `INSERT` in a loop) pay parse cost on every execution.

**Proposed solution:** Add `prepare`/`execute_prepared` NIFs returning a `StatementResource`, and an LRU cache (keyed by SQL string) in the connection state, mirroring Exqlite's approach. This is the natural next step once the API stabilizes — not urgent for v0.1.

**Priority:** Medium &nbsp;|&nbsp; **Effort:** Large (~1-2 days)

### 2.3 Full result materialization; cursors unsupported — **Low**

**Issue:** `query` collects all rows into memory before returning, and `handle_declare/fetch` return "cursors are not supported" (`connection.ex:145-157`). Large result sets can blow up memory with no streaming escape hatch.

**Proposed solution:** Fine for v0.1 (and documented). When needed, implement `handle_declare`/`handle_fetch` over a `RowsResource` holding the turso row stream, fetching N rows per NIF call.

**Priority:** Low &nbsp;|&nbsp; **Effort:** Large

### 2.4 Tokio built with `features = ["full"]` — **Low**

**Issue:** `native/ex_turso/Cargo.toml` pulls in all of Tokio (signal handling, process, fs, io drivers...) when only a multi-threaded runtime is used. Inflates compile time and binary size.

**Current code:**

```toml
tokio = { version = "1", features = ["full"] }
```

**Proposed solution:** `features = ["rt-multi-thread"]` (add `"macros"` if needed). Also consider capping worker threads (`Builder::new_multi_thread().worker_threads(2)`) — the runtime only services `block_on` calls from dirty schedulers, so a thread per core is wasted.

**Priority:** Low &nbsp;|&nbsp; **Effort:** Trivial (~15min + verify build)

### 2.5 Dirty IO scheduler saturation with large pools — **Low (informational)**

**Issue:** Every NIF blocks a dirty IO scheduler thread for the full duration of the query (`block_on`). The BEAM default is 10 dirty IO threads; a `pool_size` above that with slow queries will queue all other dirty IO work in the VM (including file IO from other libraries).

**Proposed solution:** Document the interaction (`+SDio` flag) in the README. Long-term, the cleaner fix is async NIFs that spawn onto the Tokio runtime and send a message back to the calling process instead of blocking.

**Priority:** Low &nbsp;|&nbsp; **Effort:** Doc-only now; async NIFs are a large change

---

## 3. Architecture Suggestions

### 3.1 No error classification — everything is a message string — **High**

**Issue:** The NIF layer flattens every turso error to `e.to_string()`, and `%ExTurso.Error{}` has only `:message`. Consequences:

- Callers can't distinguish `SQLITE_BUSY`/locked (retryable) from constraint violations (caller bug) from IO errors (connection is broken).
- `handle_execute/4` always returns `{:error, ...}`, keeping the connection checked in even when the underlying connection is dead. `AGENTS.md` (§Actor 2, Failure Modes) claims IO errors return `{:disconnect, ...}` — the code never does this outside of `BEGIN`/`COMMIT`/`ROLLBACK`. Doc and code disagree.
- Tests must match on exact English strings (see `test/ex_turso_test.exs:103-110, 179-196`), which makes messages load-bearing.

**Current code** (`lib/ex_turso/error.ex`):

```elixir
defexception [:message]
```

**Proposed solution:** Return structured errors from Rust, e.g. `{:error, {:busy | :constraint | :io | :sql | :other, message}}`, add a `:code` field to `ExTurso.Error`, and route `:io`-class errors to `{:disconnect, ...}` in `handle_execute/4`. This unlocks caller-side retry logic and makes the pool actually replace dead connections.

**Priority:** High &nbsp;|&nbsp; **Effort:** Medium (~half day; Rust error mapping + Connection routing + tests)

### 3.2 `ping/1` is a no-op — **Medium**

**Issue:** `ping/1` (`connection.ex:68`) returns `{:ok, state}` unconditionally, so DBConnection's idle ping can never detect a broken connection (e.g. database file deleted, sync replica corrupted). Dead connections stay in the pool until a query fails on a real caller.

**Current code:**

```elixir
def ping(state), do: {:ok, state}
```

**Proposed solution:**

```elixir
def ping(%__MODULE__{conn: conn} = state) do
  case Native.query(conn, "SELECT 1", []) do
    {:ok, _} -> {:ok, state}
    {:error, reason} -> {:disconnect, %Error{message: reason}, state}
  end
end
```

**Priority:** Medium &nbsp;|&nbsp; **Effort:** Small (~30min with test)

### 3.3 Hex package readiness gap — **Medium**

**Issue:** The README documents installation via `{:ex_turso, "~> 0.1.0"}` from Hex, but the project isn't publishable as documented:

- `mix.exs` has no `package`, `description`, `source_url`, or `docs` config, and no `ex_doc` dep.
- No `LICENSE` file (Hex requires a license); `Cargo.toml` has empty `authors` and no `license` field.
- No `CHANGELOG.md`.
- Most importantly: published Hex consumers would need a full Rust toolchain. Consider `rustler_precompiled` for prebuilt NIF binaries — `release.yml` already exists and could feed it.

**Proposed solution:** Add package metadata + LICENSE + `ex_doc`; evaluate `rustler_precompiled` before first publish.

**Priority:** Medium (High if publishing soon) &nbsp;|&nbsp; **Effort:** Small for metadata (~1h); Medium for rustler_precompiled (~1 day)

### 3.4 `:mode` option on transactions silently ignored — **Low**

**Issue:** `handle_begin/2` ignores `opts`. Callers used to Postgrex may pass `mode: :savepoint` for nested transactions; ExTurso will issue a plain `BEGIN`, which fails inside an open transaction and tears down the connection via `{:disconnect, ...}`.

**Proposed solution:** Either implement savepoints (`SAVEPOINT name` / `RELEASE` / `ROLLBACK TO`) or fail fast with a clear "savepoints not supported" error when `opts[:mode] == :savepoint`. SQLite also supports `BEGIN IMMEDIATE`/`EXCLUSIVE`, which would be a useful `:mode` to expose for write-heavy workloads.

**Priority:** Low &nbsp;|&nbsp; **Effort:** Small for the guard; Medium for savepoint support

---

## 4. Security Issues

### 4.1 `auth_token` lives in plaintext in pool opts — **Medium**

**Issue:** `connect/1` reads `opts[:auth_token]` directly. These opts are part of the child spec / DBConnection state, so the token can leak into supervisor crash reports, `:sys.get_state` output, and observer. There's no redaction or indirection.

**Current code** (`connection.ex:29`):

```elixir
auth_token = opts[:auth_token]
```

**Proposed solution:** Accept a zero-arity function or `{:system, "ENV_VAR"}` tuple and resolve it inside `connect/1` (the pattern used by `Postgrex` `:password` and `Req` auth). Document that tokens should come from the environment, not compile-time config.

**Priority:** Medium &nbsp;|&nbsp; **Effort:** Small (~1h)

### 4.2 Full SQL statements appear in logs/exceptions — **Low (informational)**

**Issue:** `String.Chars` for `ExTurso.Query` returns the raw statement, and DBConnection logs queries on errors. Anyone interpolating sensitive values into SQL (instead of using params) will leak them into logs. Parameterized queries are fully supported, so this is only an awareness item.

**Proposed solution:** One README sentence: "always pass values as params; statements are logged on error." No code change.

**Priority:** Low &nbsp;|&nbsp; **Effort:** Trivial

*No injection, unsafe-Rust, or dependency vulnerabilities found. Parameter binding goes through `turso::Value` (never string interpolation), NIF resources are correctly lifetime-managed via `ResourceArc`, and `Cargo.lock`/`mix.lock` are committed and CI builds with `--locked`.*

---

## 5. Testing Improvements

### 5.1 Concurrent-pool test silently swallows failures — **High**

**Issue:** The comprehension filter in `test/ex_turso_test.exs:152-154` only iterates over results that match the success shape. If all 50 concurrent queries failed, **zero assertions would run and the test would still pass**. The test currently verifies nothing.

**Current code:**

```elixir
for {:ok, {:ok, %Result{rows: [%{"val" => val}]}} <- results do
  assert val in 1..50
end
```

**Proposed solution:**

```elixir
assert length(results) == 50

for {:ok, result} <- results do
  assert {:ok, %Result{rows: [%{"val" => val}]}} = result
  assert val in 1..50
end
```

**Priority:** High &nbsp;|&nbsp; **Effort:** Trivial (~10min)

### 5.2 No coverage of parameter-coercion edge cases — **Medium**

**Issue:** No tests pin the behavior for `true`/`false`, atoms, bignums (`2**64`), or negative blobs-vs-text boundaries. Today these silently become `NULL` (see 1.1); whatever behavior is chosen, it should be locked in by tests so a rustler upgrade can't silently change it.

**Proposed solution:** Add a test per category. If 1.1 is implemented, assert the error; until then, assert the (current) NULL coercion with a comment marking it as known-bad.

**Priority:** Medium &nbsp;|&nbsp; **Effort:** Small (~1h)

### 5.3 Sync happy path is untested (and untestable locally) — **Medium**

**Issue:** All sync tests cover error/validation paths (`ex_turso_test.exs:178-208`). `Native.open_sync/3`, `connect_sync/1`, and a successful `sync/1` are never executed in the suite — the Rust sync code paths (`lib.rs:128-177`) have zero coverage. A regression there ships green.

**Proposed solution:** Two layers: (a) a `@tag :integration`-gated test against a real Turso database driven by env vars, wired into the existing `e2e.yml` workflow with repo secrets; (b) if turso ships a local sync test server, use it. At minimum, add a test that `open_sync` with an unreachable URL returns `{:error, _}` rather than hanging — guarded with a generous timeout since it touches the network stack.

**Priority:** Medium &nbsp;|&nbsp; **Effort:** Medium (~half day incl. CI wiring)

### 5.4 Pool recovery after `{:disconnect, ...}` untested — **Low**

**Issue:** Nothing verifies that the pool replaces a connection after a disconnect-class failure (e.g. failed `COMMIT`) and that subsequent queries succeed on the fresh connection — the core fault-tolerance claim of AGENTS.md.

**Proposed solution:** A test that forces a transaction failure, then asserts the next query on the same pool succeeds.

**Priority:** Low &nbsp;|&nbsp; **Effort:** Small (~1h)

---

## 6. Documentation Gaps

### 6.1 README contradicts the implemented feature set — **High**

**Issue:** README line 8-9 says: *"Turso Cloud, embedded replica sync, vector search, and migrations are intentionally out of scope."* But cloud sync **is implemented** (`open_sync`/`connect_sync`/`sync` NIFs, `ExTurso.sync/2`, `:remote_url`/`:auth_token` options) and vector search is tested (`ex_turso_test.exs:157`). Nothing in the README tells users how to configure a synced replica. The architecture table also omits the sync layer.

**Proposed solution:** Update the scope paragraph, add a "Turso Cloud sync" usage section (`{ExTurso, database: "replica.db", remote_url: "libsql://...", auth_token: ..., name: MyApp.DB}` + `ExTurso.sync/2`), and refresh the architecture table.

**Priority:** High &nbsp;|&nbsp; **Effort:** Small (~30min)

### 6.2 `ExTurso` moduledoc lists `:database` as the only option — **Medium**

**Issue:** `lib/ex_turso.ex:24-28` states: *"The only ExTurso-specific option is: `:database`"*. `:remote_url` and `:auth_token` are now also ExTurso-specific options handled in `Connection.connect/1`, and they're documented nowhere in the Elixir docs.

**Proposed solution:** Document all three options in the moduledoc and in `start_link/1`'s doc.

**Priority:** Medium &nbsp;|&nbsp; **Effort:** Trivial (~15min)

### 6.3 `ExTurso.Query` moduledoc omits `:sync` — **Low**

**Issue:** `lib/ex_turso/query.ex:4-9` documents `command` as selecting `:query` or `:execute`, but the type and the Connection both handle `:sync`.

**Proposed solution:** Add the `:sync` bullet ("triggers replica sync via `ExTurso.Native.sync/1`; statement text is ignored").

**Priority:** Low &nbsp;|&nbsp; **Effort:** Trivial

### 6.4 AGENTS.md failure-mode claims don't match the code — **Low**

**Issue:** AGENTS.md §Actor 2 says IO/locked errors during execution return `{:disconnect, ...}`; the implementation returns `{:error, ...}` for all statement failures (see 3.1). AGENTS.md §Actor 3 also lists a `prepare` no-op signal but documents the architecture as if statements were prepared.

**Proposed solution:** Either implement error classification (3.1) so the doc becomes true, or amend AGENTS.md to describe actual behavior. Don't leave them disagreeing — this file is consumed by agents as ground truth.

**Priority:** Low (rises to Medium if 3.1 is not done) &nbsp;|&nbsp; **Effort:** Trivial

---

## Suggested Order of Attack

Status as of 2026-06-11: items 1–7 implemented (plus the coercion-test half of item 8, and 6.4 AGENTS.md alignment as part of item 4).

| # | Item | Priority | Effort | Status |
|---|------|----------|--------|--------|
| 1 | 5.1 Fix concurrent test that can't fail | High | Trivial | ✅ Done |
| 2 | 6.1 README scope/sync section | High | Small | ✅ Done |
| 3 | 1.1 Reject unsupported params instead of silent NULL | High | Small | ✅ Done |
| 4 | 3.1 Structured errors + disconnect routing | High | Medium | ✅ Done |
| 5 | 6.2 / 6.3 Moduledoc option drift | Medium | Trivial | ✅ Done |
| 6 | 3.2 Real `ping/1` | Medium | Small | ✅ Done |
| 7 | 4.1 `auth_token` indirection/redaction | Medium | Small | ✅ Done |
| 8 | 5.2 / 5.3 Coercion + sync test coverage | Medium | Small–Medium | ◐ Coercion tests done; sync e2e open |
| 9 | 3.3 Hex packaging (license, metadata, precompiled NIFs) | Medium | Small–Large | Open |
| 10 | 2.1 / 2.2 Result shape + prepared statements | Medium | Medium–Large | Open |
