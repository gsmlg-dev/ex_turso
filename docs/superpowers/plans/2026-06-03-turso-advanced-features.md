# Turso Advanced Features Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement Vector Search verification tests and add Cloud Sync/Replication features to `ExTurso` using the `turso` crate's native synchronization API.

**Architecture:** Extend the Rustler NIF with `open_sync`, `connect_sync`, and `sync` functions. Enhance `ExTurso.Connection` to manage local replica sync states and route sync requests via a new `:sync` command through the standard `DBConnection` execution pipeline.

**Tech Stack:** Elixir, Rust, Rustler, `turso` (v0.5.3) crate with `sync` feature.

---

### Task 1: Add Vector Search SQL Tests

**Files:**
- Modify: `test/ex_turso_test.exs`

- [ ] **Step 1: Write Vector Search verification test**

Add the following test at the end of the test file `test/ex_turso_test.exs`:

```elixir
  test "vector search functions compile and execute successfully", %{db: db} do
    # Create table with vector column (represented as F32_BLOB or general BLOB)
    {:ok, _} = ExTurso.execute(db, "CREATE TABLE items_vector (id INTEGER, embedding BLOB)")

    # Insert float vector data using SQLite vector representation
    {:ok, _} = ExTurso.execute(db, "INSERT INTO items_vector VALUES (?, vector32('[1.0, 2.0, 3.0]'))", [1])
    {:ok, _} = ExTurso.execute(db, "INSERT INTO items_vector VALUES (?, vector32('[4.0, 5.0, 6.0]'))", [2])

    # Query with vector distance calculation (using cosine similarity/distance)
    assert {:ok, %Result{rows: [%{"id" => 1, "distance" => distance}]}} =
             ExTurso.query(
               db,
               "SELECT id, vector_distance_cos(embedding, vector32('[1.0, 2.0, 3.0]')) as distance FROM items_vector ORDER BY distance LIMIT 1"
             )

    assert abs(distance) < 1.0e-5
  end
```

- [ ] **Step 2: Run test suite to verify the vector features**

Run: `mix test`
Expected: PASS (if the local embedded `turso` crate supports vector functions out of the box).

- [ ] **Step 3: Commit**

```bash
git add test/ex_turso_test.exs
git commit -m "test: add vector search query and distance verification tests"
```

---

### Task 2: Enable Cargo Sync Feature

**Files:**
- Modify: `native/ex_turso/Cargo.toml`

- [ ] **Step 1: Enable the "sync" feature in dependencies**

Replace line 13 in `native/ex_turso/Cargo.toml`:
```toml
turso = "0.5"
```
with:
```toml
turso = { version = "0.5", features = ["sync"] }
```

- [ ] **Step 2: Verify cargo compilation succeeds**

Run: `mix compile`
Expected: compilation completes successfully and fetches the required `sync` feature dependencies of the `turso` crate.

- [ ] **Step 3: Commit**

```bash
git add native/ex_turso/Cargo.toml
git commit -m "cargo: enable sync feature flag on turso crate dependency"
```

---

### Task 3: Expose Sync APIs in Rust NIF

**Files:**
- Modify: `native/ex_turso/src/lib.rs`

- [ ] **Step 1: Implement Sync NIF functions and resources**

Add `SyncDbResource`, `open_sync`, `connect_sync`, and `sync` to `native/ex_turso/src/lib.rs`:

Define `SyncDbResource` resource type:
```rust
/// Resource wrapping an open `turso::sync::Database`.
struct SyncDbResource {
    inner: Mutex<turso::sync::Database>,
}

#[rustler::resource_impl]
impl rustler::Resource for SyncDbResource {}
```

Add these functions:
```rust
/// Open (or create) a local database synced with a remote database.
#[rustler::nif(schedule = "DirtyIo")]
fn open_sync(
    path: String,
    remote_url: String,
    auth_token: String,
) -> Result<ResourceArc<SyncDbResource>, String> {
    let result = RT.block_on(async {
        turso::sync::Builder::new_remote(&path)
            .with_remote_url(&remote_url)
            .with_auth_token(&auth_token)
            .build()
            .await
    });
    match result {
        Ok(db) => Ok(ResourceArc::new(SyncDbResource {
            inner: Mutex::new(db),
        })),
        Err(e) => Err(e.to_string()),
    }
}

/// Open a connection against a synced database.
#[rustler::nif(schedule = "DirtyIo")]
fn connect_sync(
    db: ResourceArc<SyncDbResource>,
) -> Result<ResourceArc<ConnResource>, String> {
    let guard = db.inner.lock().map_err(|e| e.to_string())?;
    match guard.connect() {
        Ok(conn) => Ok(ResourceArc::new(ConnResource {
            inner: Mutex::new(conn),
        })),
        Err(e) => Err(e.to_string()),
    }
}

/// Run bidirectional sync.
#[rustler::nif(schedule = "DirtyIo")]
fn sync(db: ResourceArc<SyncDbResource>) -> Result<rustler::types::atom::Atom, String> {
    let guard = db.inner.lock().map_err(|e| e.to_string())?;
    RT.block_on(async { guard.sync().await.map_err(|e| e.to_string()) })?;
    Ok(atoms::ok())
}
```

Update `rustler::init!` to declare the new NIF functions:
```rust
rustler::init!(
    "Elixir.ExTurso.Native",
    [
        open,
        connect,
        query,
        execute,
        close,
        open_sync,
        connect_sync,
        sync
    ]
);
```

- [ ] **Step 2: Compile native crate**

Run: `mix compile`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add native/ex_turso/src/lib.rs
git commit -m "nif: implement open_sync, connect_sync, and sync NIF functions"
```

---

### Task 4: Expose Sync APIs in Elixir Native Layer

**Files:**
- Modify: `lib/ex_turso/native.ex`

- [ ] **Step 1: Declare NIF functions in Native module**

Add the following function stubs to `lib/ex_turso/native.ex`:

```elixir
  @doc "Open a synced local replica of a remote database. Returns `{:ok, sync_db}` or `{:error, reason}`."
  @spec open_sync(String.t(), String.t(), String.t()) :: {:ok, reference()} | {:error, String.t()}
  def open_sync(_path, _remote_url, _auth_token), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Open a connection against a synced database handle."
  @spec connect_sync(reference()) :: {:ok, reference()} | {:error, String.t()}
  def connect_sync(_db), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Triggers a sync on a replica database handle. Returns `:ok` or `{:error, reason}`."
  @spec sync(reference()) :: :ok | {:error, String.t()}
  def sync(_db), do: :erlang.nif_error(:nif_not_loaded)
```

- [ ] **Step 2: Run test suite to verify code compiles**

Run: `mix test`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add lib/ex_turso/native.ex
git commit -m "feat: expose open_sync, connect_sync, and sync function stubs in Native"
```

---

### Task 5: Support Synced Databases in Connection Actor

**Files:**
- Modify: `lib/ex_turso/connection.ex`

- [ ] **Step 1: Update ExTurso.Connection struct and callbacks**

Update the struct definition to support `:sync_db`:
```elixir
  @type t :: %__MODULE__{
          db: reference(),
          conn: reference(),
          sync_db: reference() | nil,
          status: :idle | :transaction
        }

  defstruct [:db, :conn, :sync_db, status: :idle]
```

Modify `connect/1` callback to parse `:remote_url` and `:auth_token`:
```elixir
  @impl true
  def connect(opts) do
    database = Keyword.fetch!(opts, :database)
    remote_url = opts[:remote_url]
    auth_token = opts[:auth_token]

    result =
      if remote_url && auth_token do
        with {:ok, db} <- Native.open_sync(database, remote_url, auth_token),
             {:ok, conn} <- Native.connect_sync(db) do
          {:ok, db, conn, true}
        end
      else
        with {:ok, db} <- Native.open(database),
             {:ok, conn} <- Native.connect(db) do
          {:ok, db, conn, false}
        end
      end

    case result do
      {:ok, db, conn, is_sync} ->
        {:ok, %__MODULE__{db: db, conn: conn, sync_db: if(is_sync, do: db, else: nil)}}

      {:error, reason} ->
        {:error, %Error{message: reason}}
    end
  end
```

Modify `handle_execute/4` to handle the `:sync` command:
```elixir
  @impl true
  def handle_execute(%Query{command: :sync} = query, _params, _opts, state) do
    if state.sync_db do
      case Native.sync(state.sync_db) do
        :ok -> {:ok, query, %Result{rows: nil, num_rows: 0}, state}
        {:error, reason} -> {:error, %Error{message: reason}, state}
      end
    else
      {:error, %Error{message: "database is not configured for cloud sync"}, state}
    end
  end

  def handle_execute(%Query{command: :query, statement: sql} = query, params, _opts, state) do
```

- [ ] **Step 2: Run test suite to verify compilation**

Run: `mix test`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add lib/ex_turso/connection.ex
git commit -m "feat: handle sync connection creation and sync execution requests"
```

---

### Task 6: Expose `ExTurso.sync/2` API and Add Tests

**Files:**
- Modify: `lib/ex_turso/query.ex`
- Modify: `lib/ex_turso.ex`
- Modify: `test/ex_turso_test.exs`

- [ ] **Step 1: Extend Query command type**

In `lib/ex_turso/query.ex`, update the command type definition:
```elixir
  @type command :: :query | :execute | :sync
```

- [ ] **Step 2: Implement `ExTurso.sync/2`**

In `lib/ex_turso.ex`, implement the `sync` function:
```elixir
  @doc """
  Triggers a synchronization of the local replica database with the remote Turso Cloud database.
  """
  @spec sync(conn(), keyword()) :: :ok | {:error, Exception.t()}
  def sync(conn, opts \\ []) do
    query = %Query{statement: "SYNC", command: :sync}

    case DBConnection.execute(conn, query, [], opts) do
      {:ok, _query, _result} -> :ok
      {:error, _exception} = error -> error
    end
  end
```

- [ ] **Step 3: Write tests for sync verification**

Add the following tests to `test/ex_turso_test.exs`:

```elixir
  test "sync/2 returns error if database is not configured for sync", %{db: db} do
    assert {:error, %ExTurso.Error{message: "database is not configured for cloud sync"}} =
             ExTurso.sync(db)
  end
```

- [ ] **Step 4: Run test suite**

Run: `mix test`
Expected: PASS (all 16 tests pass)

- [ ] **Step 5: Commit**

```bash
git add lib/ex_turso/query.ex lib/ex_turso.ex test/ex_turso_test.exs
git commit -m "feat: expose public sync API and add sync error state test"
```
