defmodule ExTursoE2E.TransactionPoolTest do
  use ExUnit.Case, async: true

  alias ExTurso.Result
  alias ExTursoE2E.Support

  @moduletag :tmp_dir

  test "transactions commit and roll back through DBConnection", %{tmp_dir: tmp_dir} do
    {db, _pid} =
      Support.start_pool!(database: Path.join(tmp_dir, "transactions.db"), pool_size: 1)

    Support.execute!(db, "CREATE TABLE accounts (id INTEGER PRIMARY KEY, balance INTEGER)")
    Support.execute!(db, "INSERT INTO accounts VALUES (?, ?)", [1, 100])

    assert {:ok, :committed} =
             DBConnection.transaction(db, fn conn ->
               Support.execute!(conn, "UPDATE accounts SET balance = balance + ? WHERE id = ?", [
                 25,
                 1
               ])

               :committed
             end)

    assert %{"balance" => 125} =
             Support.query_one!(db, "SELECT balance FROM accounts WHERE id = ?", [1])

    assert {:error, :rollback} =
             DBConnection.transaction(db, fn conn ->
               Support.execute!(conn, "UPDATE accounts SET balance = balance + ? WHERE id = ?", [
                 999,
                 1
               ])

               DBConnection.rollback(conn, :rollback)
             end)

    assert %{"balance" => 125} =
             Support.query_one!(db, "SELECT balance FROM accounts WHERE id = ?", [1])
  end

  test "a file-backed pool handles concurrent work", %{tmp_dir: tmp_dir} do
    {db, _pid} =
      Support.start_pool!(database: Path.join(tmp_dir, "concurrent.db"), pool_size: 4)

    Support.execute!(db, "CREATE TABLE events (id INTEGER PRIMARY KEY, label TEXT NOT NULL)")

    results =
      1..40
      |> Task.async_stream(
        fn id ->
          insert_with_busy_retry(db, id)
        end,
        max_concurrency: 4,
        timeout: 30_000
      )
      |> Enum.to_list()

    assert length(results) == 40

    for {:ok, result} <- results do
      assert {:ok, %Result{num_rows: 1, rows: nil}} = result
    end

    assert {:ok, %Result{rows: [%{"count" => 40, "total" => 820}]}} =
             ExTurso.query(db, "SELECT count(*) AS count, sum(id) AS total FROM events")
  end

  test "recoverable SQL errors do not poison the pool", %{tmp_dir: tmp_dir} do
    {db, _pid} =
      Support.start_pool!(database: Path.join(tmp_dir, "recoverable.db"), pool_size: 2)

    assert {:error, %ExTurso.Error{code: :error}} =
             ExTurso.query(db, "SELECT * FROM missing_table")

    assert {:ok, %Result{rows: [%{"ok" => 1}]}} = ExTurso.query(db, "SELECT 1 AS ok")
  end

  defp insert_with_busy_retry(db, id, attempts_left \\ 10)

  defp insert_with_busy_retry(db, id, attempts_left) when attempts_left > 0 do
    case ExTurso.execute(db, "INSERT INTO events VALUES (?, ?)", [id, "event-#{id}"]) do
      {:error, %ExTurso.Error{code: :busy}} ->
        Process.sleep(10)
        insert_with_busy_retry(db, id, attempts_left - 1)

      result ->
        result
    end
  end

  defp insert_with_busy_retry(db, id, 0) do
    ExTurso.execute(db, "INSERT INTO events VALUES (?, ?)", [id, "event-#{id}"])
  end
end
