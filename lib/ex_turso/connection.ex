defmodule ExTurso.Connection do
  @moduledoc """
  `DBConnection` implementation backed by a local turso database.

  Each pooled connection opens its own database handle and connection via the
  native layer. Connection options:

    * `:database` — path to the local database file (required). `":memory:"`
      opens an in-memory database.
  """

  use DBConnection

  alias ExTurso.{Error, Native, Query, Result}

  @type t :: %__MODULE__{
          db: reference(),
          conn: reference(),
          status: :idle | :transaction
        }

  defstruct [:db, :conn, status: :idle]

  @impl true
  def connect(opts) do
    database = Keyword.fetch!(opts, :database)

    with {:ok, db} <- Native.open(database),
         {:ok, conn} <- Native.connect(db) do
      {:ok, %__MODULE__{db: db, conn: conn}}
    else
      {:error, reason} -> {:error, %Error{message: reason}}
    end
  end

  @impl true
  def disconnect(_err, %__MODULE__{conn: conn}) do
    Native.close(conn)
    :ok
  end

  @impl true
  def checkout(state), do: {:ok, state}

  @impl true
  def ping(state), do: {:ok, state}

  @impl true
  def handle_status(_opts, %__MODULE__{status: status} = state), do: {status, state}

  @impl true
  def handle_begin(_opts, %__MODULE__{conn: conn} = state) do
    case Native.execute(conn, "BEGIN", []) do
      {:ok, _} -> {:ok, %Result{}, %{state | status: :transaction}}
      {:error, reason} -> {:disconnect, %Error{message: reason}, state}
    end
  end

  @impl true
  def handle_commit(_opts, %__MODULE__{conn: conn} = state) do
    case Native.execute(conn, "COMMIT", []) do
      {:ok, _} -> {:ok, %Result{}, %{state | status: :idle}}
      {:error, reason} -> {:disconnect, %Error{message: reason}, state}
    end
  end

  @impl true
  def handle_rollback(_opts, %__MODULE__{conn: conn} = state) do
    case Native.execute(conn, "ROLLBACK", []) do
      {:ok, _} -> {:ok, %Result{}, %{state | status: :idle}}
      {:error, reason} -> {:disconnect, %Error{message: reason}, state}
    end
  end

  @impl true
  def handle_execute(%Query{command: :query, statement: sql} = query, params, _opts, state) do
    case Native.query(state.conn, sql, params) do
      {:ok, rows} ->
        {:ok, query, %Result{rows: rows, num_rows: length(rows)}, state}

      {:error, reason} ->
        {:error, %Error{message: reason}, state}
    end
  end

  def handle_execute(%Query{command: :execute, statement: sql} = query, params, _opts, state) do
    case Native.execute(state.conn, sql, params) do
      {:ok, affected} ->
        {:ok, query, %Result{rows: nil, num_rows: affected}, state}

      {:error, reason} ->
        {:error, %Error{message: reason}, state}
    end
  end

  # Statements are not prepared server-side; prepare/close are no-ops so the
  # query flows straight to handle_execute/4.
  @impl true
  def handle_prepare(query, _opts, state), do: {:ok, query, state}

  @impl true
  def handle_close(_query, _opts, state), do: {:ok, %Result{}, state}

  # Server-side cursors are not supported.
  @impl true
  def handle_declare(_query, _params, _opts, state) do
    {:error, %Error{message: "cursors are not supported"}, state}
  end

  @impl true
  def handle_fetch(_query, _cursor, _opts, state) do
    {:error, %Error{message: "cursors are not supported"}, state}
  end

  @impl true
  def handle_deallocate(_query, _cursor, _opts, state) do
    {:error, %Error{message: "cursors are not supported"}, state}
  end
end
