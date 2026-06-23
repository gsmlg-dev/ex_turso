defmodule ExTursoE2E.CloudSyncTest do
  use ExUnit.Case, async: false

  alias ExTurso.Result
  alias ExTursoE2E.Support

  @moduletag :cloud
  @moduletag :tmp_dir

  test "two local replicas synchronize through Turso Cloud", %{tmp_dir: tmp_dir} do
    remote_url = fetch_env!("TURSO_E2E_DATABASE_URL")
    auth_token = fetch_env!("TURSO_E2E_AUTH_TOKEN")
    run_id = "ex_turso_e2e_#{System.unique_integer([:positive])}"

    {left, _pid} =
      Support.start_pool!(
        database: Path.join(tmp_dir, "left.db"),
        remote_url: remote_url,
        auth_token: fn -> auth_token end,
        pool_size: 1
      )

    {right, _pid} =
      Support.start_pool!(
        database: Path.join(tmp_dir, "right.db"),
        remote_url: remote_url,
        auth_token: auth_token,
        pool_size: 1
      )

    assert :ok = ExTurso.sync(left)
    assert :ok = ExTurso.sync(right)

    Support.execute!(
      left,
      """
      CREATE TABLE IF NOT EXISTS ex_turso_e2e_sync (
        run_id TEXT NOT NULL,
        side TEXT NOT NULL,
        value INTEGER NOT NULL,
        PRIMARY KEY (run_id, side)
      )
      """
    )

    Support.execute!(left, "DELETE FROM ex_turso_e2e_sync WHERE run_id = ?", [run_id])
    Support.execute!(left, "INSERT INTO ex_turso_e2e_sync VALUES (?, ?, ?)", [run_id, "left", 1])
    assert :ok = ExTurso.sync(left)
    assert :ok = ExTurso.sync(right)

    assert {:ok, %Result{rows: [%{"value" => 1}]}} =
             ExTurso.query(
               right,
               "SELECT value FROM ex_turso_e2e_sync WHERE run_id = ? AND side = ?",
               [run_id, "left"]
             )

    Support.execute!(right, "INSERT INTO ex_turso_e2e_sync VALUES (?, ?, ?)", [
      run_id,
      "right",
      2
    ])

    assert :ok = ExTurso.sync(right)
    assert :ok = ExTurso.sync(left)

    assert {:ok, %Result{rows: [%{"total" => 3}]}} =
             ExTurso.query(
               left,
               "SELECT sum(value) AS total FROM ex_turso_e2e_sync WHERE run_id = ?",
               [
                 run_id
               ]
             )

    Support.execute!(left, "DELETE FROM ex_turso_e2e_sync WHERE run_id = ?", [run_id])
    assert :ok = ExTurso.sync(left)
  end

  test "sync is rejected inside a transaction", %{tmp_dir: tmp_dir} do
    remote_url = fetch_env!("TURSO_E2E_DATABASE_URL")
    auth_token = fetch_env!("TURSO_E2E_AUTH_TOKEN")

    {db, _pid} =
      Support.start_pool!(
        database: Path.join(tmp_dir, "transaction-sync.db"),
        remote_url: remote_url,
        auth_token: fn -> auth_token end,
        pool_size: 1
      )

    assert {:error, %ExTurso.Error{message: "cannot sync database inside a transaction"}} =
             DBConnection.transaction(db, fn conn ->
               case ExTurso.sync(conn) do
                 {:error, err} -> DBConnection.rollback(conn, err)
                 :ok -> :ok
               end
             end)
  end

  defp fetch_env!(name) do
    System.get_env(name) || flunk("#{name} is required for cloud sync e2e tests")
  end
end
