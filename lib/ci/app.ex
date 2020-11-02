defmodule Ci.App do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    Supervisor.start_link(
      [
        OsCmd.Faker
      ],
      strategy: :one_for_one,
      name: __MODULE__
    )
  end
end
