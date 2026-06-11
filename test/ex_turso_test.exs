defmodule ExTursoTest do
  use ExUnit.Case, async: true

  alias ExTurso.Result

  setup do
    # Each test gets its own in-memory database with a single connection so the
    # data stays on one handle.
    name = :"db_#{System.unique_integer([:positive])}"
    start_supervised!({ExTurso, database: ":memory:", name: name, pool_size: 1})
    {:ok, _} = ExTurso.execute(name, "CREATE TABLE users (id INTEGER, name TEXT, score REAL)")
    %{db: name}
  end

  test "execute reports affected rows", %{db: db} do
    assert {:ok, %Result{num_rows: 1, rows: nil}} =
             ExTurso.execute(db, "INSERT INTO users VALUES (?, ?, ?)", [1, "Alice", 9.5])
  end

  test "query returns rows as maps keyed by column name", %{db: db} do
    {:ok, _} = ExTurso.execute(db, "INSERT INTO users VALUES (?, ?, ?)", [1, "Alice", 9.5])

    assert {:ok, %Result{num_rows: 1, rows: [%{"id" => 1, "name" => "Alice", "score" => 9.5}]}} =
             ExTurso.query(db, "SELECT id, name, score FROM users WHERE id = ?", [1])
  end

  test "parameters bind across types including nil", %{db: db} do
    {:ok, _} = ExTurso.execute(db, "INSERT INTO users VALUES (?, ?, ?)", [2, "Bob", nil])

    assert {:ok, %Result{rows: [%{"name" => "Bob", "score" => nil}]}} =
             ExTurso.query(db, "SELECT name, score FROM users WHERE id = ?", [2])
  end

  test "empty result set", %{db: db} do
    assert {:ok, %Result{num_rows: 0, rows: []}} =
             ExTurso.query(db, "SELECT * FROM users", [])
  end

  test "errors surface as {:error, exception}", %{db: db} do
    assert {:error, %ExTurso.Error{message: message}} =
             ExTurso.query(db, "SELECT * FROM nonexistent", [])

    assert is_binary(message)
  end

  test "transaction commits", %{db: db} do
    {:ok, _} = ExTurso.execute(db, "INSERT INTO users VALUES (?, ?, ?)", [1, "Alice", 1.0])

    assert {:ok, :done} =
             DBConnection.transaction(db, fn conn ->
               {:ok, _} =
                 ExTurso.execute(conn, "UPDATE users SET score = ? WHERE id = ?", [10.0, 1])

               :done
             end)

    assert {:ok, %Result{rows: [%{"score" => 10.0}]}} =
             ExTurso.query(db, "SELECT score FROM users WHERE id = ?", [1])
  end

  test "transaction rolls back on error", %{db: db} do
    {:ok, _} = ExTurso.execute(db, "INSERT INTO users VALUES (?, ?, ?)", [1, "Alice", 1.0])

    assert {:error, :boom} =
             DBConnection.transaction(db, fn conn ->
               {:ok, _} =
                 ExTurso.execute(conn, "UPDATE users SET score = ? WHERE id = ?", [99.0, 1])

               DBConnection.rollback(conn, :boom)
             end)

    assert {:ok, %Result{rows: [%{"score" => 1.0}]}} =
             ExTurso.query(db, "SELECT score FROM users WHERE id = ?", [1])
  end

  test "blob parameters bind and return as binary", %{db: db} do
    {:ok, _} = ExTurso.execute(db, "CREATE TABLE blobs (id INTEGER, data BLOB)")
    blob = <<0, 1, 2, 255>>
    {:ok, _} = ExTurso.execute(db, "INSERT INTO blobs VALUES (?, ?)", [1, blob])

    assert {:ok, %Result{rows: [%{"data" => ^blob}]}} =
             ExTurso.query(db, "SELECT data FROM blobs WHERE id = ?", [1])
  end

  test "ping/1 callback runs a real query against the connection" do
    {:ok, state} = ExTurso.Connection.connect(database: ":memory:")
    assert {:ok, ^state} = ExTurso.Connection.ping(state)
  end

  test "status changes between idle and transaction", %{db: db} do
    assert :idle = DBConnection.status(db)

    {:ok, _} =
      DBConnection.transaction(db, fn conn ->
        assert :transaction = DBConnection.status(conn)
      end)
  end

  test "cursors callbacks return unsupported error" do
    state = %ExTurso.Connection{}
    query = %ExTurso.Query{}

    assert {:error, %ExTurso.Error{message: "cursors are not supported"}, ^state} =
             ExTurso.Connection.handle_declare(query, [], [], state)

    assert {:error, %ExTurso.Error{message: "cursors are not supported"}, ^state} =
             ExTurso.Connection.handle_fetch(query, :cursor, [], state)

    assert {:error, %ExTurso.Error{message: "cursors are not supported"}, ^state} =
             ExTurso.Connection.handle_deallocate(query, :cursor, [], state)
  end

  test "connect/1 callback raises KeyError if :database is missing" do
    assert_raise KeyError, fn ->
      ExTurso.Connection.connect([])
    end
  end

  test "connect/1 callback returns error on invalid database path" do
    assert {:error, %ExTurso.Error{message: message}} = ExTurso.Connection.connect(database: "")
    assert is_binary(message)
  end

  @tag :tmp_dir
  test "handles concurrent queries with a pool", %{tmp_dir: tmp_dir} do
    db_path = Path.join(tmp_dir, "concurrent_test.db")
    pool_name = :"db_pool_#{System.unique_integer([:positive])}"

    spec = %{
      id: pool_name,
      start: {ExTurso, :start_link, [[database: db_path, name: pool_name, pool_size: 5]]}
    }

    start_supervised!(spec)

    {:ok, _} = ExTurso.execute(pool_name, "CREATE TABLE items (val INTEGER)")

    # Populate data
    for i <- 1..50 do
      {:ok, _} = ExTurso.execute(pool_name, "INSERT INTO items VALUES (?)", [i])
    end

    # Query concurrently
    results =
      1..50
      |> Task.async_stream(fn i ->
        ExTurso.query(pool_name, "SELECT val FROM items WHERE val = ?", [i])
      end)
      |> Enum.to_list()

    # Every task must have completed and every query must have succeeded.
    assert length(results) == 50

    for {:ok, result} <- results do
      assert {:ok, %Result{rows: [%{"val" => val}]}} = result
      assert val in 1..50
    end
  end

  test "vector search functions compile and execute successfully", %{db: db} do
    # Create table with vector column (represented as F32_BLOB or general BLOB)
    {:ok, _} = ExTurso.execute(db, "CREATE TABLE items_vector (id INTEGER, embedding BLOB)")

    # Insert float vector data using SQLite vector representation
    {:ok, _} =
      ExTurso.execute(db, "INSERT INTO items_vector VALUES (?, vector32('[1.0, 2.0, 3.0]'))", [1])

    {:ok, _} =
      ExTurso.execute(db, "INSERT INTO items_vector VALUES (?, vector32('[4.0, 5.0, 6.0]'))", [2])

    # Query with vector distance calculation (using cosine similarity/distance)
    assert {:ok, %Result{rows: [%{"id" => 1, "distance" => distance}]}} =
             ExTurso.query(
               db,
               "SELECT id, vector_distance_cos(embedding, vector32('[1.0, 2.0, 3.0]')) as distance FROM items_vector ORDER BY distance LIMIT 1"
             )

    assert abs(distance) < 1.0e-5
  end

  test "sync/2 returns error if database is not configured for sync", %{db: db} do
    assert {:error, %ExTurso.Error{message: "database is not configured for cloud sync"}} =
             ExTurso.sync(db)
  end

  test "sync/2 returns error if called inside a transaction", %{db: db} do
    assert {:error, %ExTurso.Error{message: "cannot sync database inside a transaction"}} =
             DBConnection.transaction(db, fn conn ->
               case ExTurso.sync(conn) do
                 {:error, err} -> DBConnection.rollback(conn, err)
                 _ -> :ok
               end
             end)
  end

  test "connect/1 returns error if only one of remote_url or auth_token is provided" do
    assert {:error,
            %ExTurso.Error{
              message: "both :remote_url and :auth_token must be provided for a synced database"
            }} =
             ExTurso.Connection.connect(
               database: ":memory:",
               remote_url: "libsql://some-url.turso.io"
             )

    assert {:error,
            %ExTurso.Error{
              message: "both :remote_url and :auth_token must be provided for a synced database"
            }} =
             ExTurso.Connection.connect(database: ":memory:", auth_token: "some-token")
  end

  test "connect/1 resolves a zero-arity function as auth_token" do
    # The function resolves to nil, so validation must treat the token as absent.
    assert {:error,
            %ExTurso.Error{
              message: "both :remote_url and :auth_token must be provided for a synced database"
            }} =
             ExTurso.Connection.connect(
               database: ":memory:",
               remote_url: "libsql://some-url.turso.io",
               auth_token: fn -> nil end
             )
  end

  test "boolean parameters bind as integers 1 and 0", %{db: db} do
    assert {:ok, %Result{rows: [%{"t" => 1, "f" => 0}]}} =
             ExTurso.query(db, "SELECT ? AS t, ? AS f", [true, false])
  end

  test "unsupported parameter types return :invalid_param instead of binding NULL", %{db: db} do
    for param <- [:some_atom, [1, 2], %{a: 1}, 36_893_488_147_419_103_232] do
      assert {:error, %ExTurso.Error{code: :invalid_param, message: message}} =
               ExTurso.query(db, "SELECT ?", [param])

      assert message =~ "index 0"
    end
  end

  test "constraint violations carry the :constraint error code", %{db: db} do
    {:ok, _} = ExTurso.execute(db, "CREATE TABLE uniq (id INTEGER PRIMARY KEY)")
    {:ok, _} = ExTurso.execute(db, "INSERT INTO uniq VALUES (?)", [1])

    assert {:error, %ExTurso.Error{code: :constraint}} =
             ExTurso.execute(db, "INSERT INTO uniq VALUES (?)", [1])
  end
end
