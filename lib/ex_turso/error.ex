defmodule ExTurso.Error do
  @moduledoc """
  Exception raised or returned when a turso operation fails. `message` carries
  the reason string produced by the native layer.
  """

  defexception [:message]

  @type t :: %__MODULE__{message: String.t()}
end
