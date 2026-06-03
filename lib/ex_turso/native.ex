defmodule ExTurso.Native do
  @moduledoc """
  Rustler NIF declarations for the `turso` crate.

  Every function here is replaced at load time by its native implementation in
  `native/ex_turso/src/lib.rs`. The bodies below only exist so the module
  compiles and raises a clear error if the NIF fails to load.

  All NIFs are scheduled on dirty IO threads and return `{:error, reason}` (with
  `reason` a string) on failure.
  """

  use Rustler, otp_app: :ex_turso, crate: "ex_turso"

  @doc "Open (or create) a local database file. Returns `{:ok, db}` or `{:error, reason}`."
  @spec open(String.t()) :: {:ok, reference()} | {:error, String.t()}
  def open(_path), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Open a connection against a database handle."
  @spec connect(reference()) :: {:ok, reference()} | {:error, String.t()}
  def connect(_db), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Run a query, returning rows as a list of maps keyed by column name."
  @spec query(reference(), String.t(), list()) ::
          {:ok, [map()]} | {:error, String.t()}
  def query(_conn, _sql, _params), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Execute a statement, returning the number of affected rows."
  @spec execute(reference(), String.t(), list()) ::
          {:ok, non_neg_integer()} | {:error, String.t()}
  def execute(_conn, _sql, _params), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Open (or create) a local database synced with a remote database."
  @spec open_sync(String.t(), String.t(), String.t()) :: {:ok, reference()} | {:error, String.t()}
  def open_sync(_path, _remote_url, _auth_token), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Open a connection against a synced database."
  @spec connect_sync(reference()) :: {:ok, reference()} | {:error, String.t()}
  def connect_sync(_db), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Run bidirectional sync."
  @spec sync(reference()) :: :ok | {:error, String.t()}
  def sync(_db), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Flush and release a connection. Returns `:ok`."
  @spec close(reference()) :: :ok
  def close(_conn), do: :erlang.nif_error(:nif_not_loaded)
end
