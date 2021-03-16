defmodule Sidekick.Supervisor do
  use Parent.GenServer
  require Logger

  @spec start_link(atom, [...]) :: GenServer.on_start()
  def start_link(parent_node, children) do
    Parent.GenServer.start_link(__MODULE__, [parent_node, children], name: __MODULE__)
  end

  @impl GenServer
  def init([parent_node, children]) do
    Node.monitor(parent_node, true)
    Parent.start_all_children!(children)
    {:ok, nil}
  end

  @impl GenServer
  def handle_info({:nodedown, _node}, state) do
    {:stop, :normal, state}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, _state) do
    Parent.shutdown_all()
    :init.stop()
  end
end
