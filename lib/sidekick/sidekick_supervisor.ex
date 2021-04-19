defmodule Sidekick.Supervisor do
  use Parent.GenServer
  require Logger

  @spec start(atom, [Parent.child_spec()]) :: GenServer.on_start()
  def start(owner_process, children) do
    # We're calling `start_link` but under the hood this will link the process to the owner process and not the caller
    Parent.GenServer.start_link(__MODULE__, {self(), owner_process, children}, name: __MODULE__)
  end

  @impl GenServer
  def init({caller_process, owner_process, children}) do
    Parent.start_all_children!(children)

    Process.unlink(caller_process)
    Process.link(owner_process)

    {:ok, %{owner_pid: owner_process}}
  end

  def handle_info({:EXIT, pid, _reason}, state) do
    if pid == state.owner_pid,
      do: {:stop, :normal, state},
      else: {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, _state) do
    Parent.shutdown_all()
    :init.stop()
  end
end
