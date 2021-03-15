defmodule Sidekick.Supervisor do
  use Parent.GenServer
  require Logger

  @spec start_link([...]) :: GenServer.on_start()
  def start_link([parent_node, children]) do
    Parent.GenServer.start_link(__MODULE__, [parent_node, children], name: __MODULE__)
  end

  @impl true
  @spec init([...]) :: {:ok, nil} | {:stop, {:shutdown, :could_not_start_all_children}}
  def init([parent_node, children]) do
    Node.monitor(parent_node, true)

    all_started =
      Enum.map(children, fn spec -> Parent.start_child(spec) end)
      |> Enum.all?(&({:ok, _pid} = &1))

    if all_started do
      {:ok, nil}
    else
      Parent.shutdown_all()
      {:stop, {:shutdown, :could_not_start_all_children}}
    end
  end

  @impl true
  def handle_info({:nodedown, _node}, state) do
    {:stop, :normal, state}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Logger.debug("Termination #{__MODULE__}")
    Parent.shutdown_all()
    :init.stop()
    state
  end
end
