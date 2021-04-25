defmodule Sidekick.Port do
  @moduledoc false

  use GenServer
  require Logger

  def start_link(caller) do
    GenServer.start_link(__MODULE__, [caller])
  end

  def open(pid, command) do
    GenServer.cast(pid, {:open, command})
  end

  @impl GenServer
  def init([caller]) do
    {:ok, {caller}}
  end

  @impl GenServer
  def handle_cast({:open, command}, {caller}) do
    port = Port.open({:spawn, command}, [:stream, :exit_status])
    {:noreply, {port, caller}}
  end

  @impl GenServer
  def handle_info({port, {:data, data}}, {port, caller}) do
    Logger.debug("Port got message #{inspect(data)}")
    {:noreply, {port, caller}}
  end

  def handle_info({module, :initialized}, {port, caller}) do
    send(caller, {module, :initialized})
    {:noreply, {port, caller}}
  end

  def handle_info({port, {:exit_status, reason}}, {port, caller}) do
    Logger.debug("Port closed with reason #{reason}")
    send(caller, :port_closed)
    {:stop, :normal, {port, caller}}
  end
end
