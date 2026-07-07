defmodule ExTursoE2E.MixProject do
  use Mix.Project

  def project do
    [
      app: :ex_turso_e2e,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    ex_turso_dep =
      case System.get_env("EX_TURSO_VERSION") do
        nil -> {:ex_turso, path: ex_turso_path()}
        version -> {:ex_turso, "== #{version}"}
      end

    rustler_dep =
      if force_native_build?() do
        [{:rustler, "~> 0.38", runtime: false}]
      else
        []
      end

    [ex_turso_dep | rustler_dep]
  end

  defp force_native_build? do
    case System.get_env("EX_TURSO_BUILD") do
      value when value in ["1", "true"] -> true
      _value -> false
    end
  end

  defp ex_turso_path do
    System.get_env("EX_TURSO_PATH") || Path.expand("..", __DIR__)
  end
end
