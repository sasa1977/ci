defmodule OsCmd.Faker do
  @moduledoc false

  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def allow(pid) do
    if match?([], :ets.lookup(__MODULE__, pid)), do: GenServer.cast(__MODULE__, {:monitor, pid})
    :ets.insert(__MODULE__, {pid, self()})
    :ok
  end

  def fetch do
    [self()]
    |> Stream.concat(Process.get(:"$callers", []))
    |> Stream.concat(Process.get(:"$ancestors", []))
    |> Stream.uniq()
    |> Enum.find_value(fn pid ->
      case :ets.lookup(__MODULE__, pid) do
        [] -> nil
        [{^pid, owner_pid}] -> owner_pid
      end
    end)
    |> case do
      nil -> :error
      pid when is_pid(pid) -> {:ok, pid}
    end
  end

  def expect(fun) do
    allow(self())
    Mox.expect(__MODULE__.Port, :start, start_handler(fun))
    :ok
  end

  def stub(fun) do
    allow(self())
    Mox.stub(__MODULE__.Port, :start, start_handler(fun))
    :ok
  end

  def start_handler(command) when is_binary(command),
    do: start_handler(fn ^command, _opts -> {:ok, 0, ""} end)

  def start_handler(fun) when is_function(fun, 2) do
    fn command, opts ->
      case fun.(command, opts) do
        {:error, _} = error ->
          error

        {:ok, exit_status, output} ->
          id = make_ref()

          if output != "",
            do: send(self(), {id, {:data, :erlang.term_to_binary({:output, output})}})

          send(self(), {id, {:exit_status, exit_status}})

          {:ok, id}
      end
    end
  end

  @impl GenServer
  def init(_) do
    :ets.new(__MODULE__, [
      :set,
      :named_table,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, nil}
  end

  @impl GenServer
  def handle_cast({:monitor, pid}, state) do
    Process.monitor(pid)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:DOWN, _mref, :process, pid, _reason}, state) do
    :ets.delete(__MODULE__, pid)
    {:noreply, state}
  end

  Mox.defmock(__MODULE__.Port, for: OsCmd.Program)
end
