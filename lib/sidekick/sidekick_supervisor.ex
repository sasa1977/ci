defmodule Sidekick.Supervisor do
  use Parent.GenServer
  require Logger

  @spec start(atom, [...]) :: GenServer.on_start()
  def start(parent_node, children) do
    # We're calling `start_link` but under the hood this will behave like `start`. See `init/1` for details.
    Parent.GenServer.start_link(__MODULE__, {self(), parent_node, children}, name: __MODULE__)
  end

  @impl GenServer
  def init({starter_process, parent_node, children}) do
    Node.monitor(parent_node, true)
    Parent.start_all_children!(children)

    # We don't want to stop when the starter process stops, so we're unlinking from it.
    Process.unlink(starter_process)

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
