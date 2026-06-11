defmodule ExTurso.Query do
  @moduledoc """
  A prepared SQL statement passed through the `DBConnection` machinery.

  `command` selects which NIF runs the statement:

    * `:query` — returns rows (via `ExTurso.Native.query/3`)
    * `:execute` — returns the affected-row count (via `ExTurso.Native.execute/3`)
    * `:sync` — triggers replica sync (via `ExTurso.Native.sync/1`); the
      statement text is ignored
  """

  @type command :: :query | :execute | :sync

  @type t :: %__MODULE__{
          statement: String.t(),
          command: command()
        }

  defstruct statement: nil, command: :query
end

defimpl DBConnection.Query, for: ExTurso.Query do
  # We do not prepare statements server-side, so parse/describe are identities
  # and encode/decode pass params and results through unchanged.
  def parse(query, _opts), do: query
  def describe(query, _opts), do: query
  def encode(_query, params, _opts), do: params
  def decode(_query, result, _opts), do: result
end

defimpl String.Chars, for: ExTurso.Query do
  def to_string(%ExTurso.Query{statement: statement}), do: statement
end
