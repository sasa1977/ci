defmodule Job do
  use Parent.GenServer

  def start_link({fun, opts}) do
    {gen_server_opts, opts} = Keyword.split(opts, ~w/name/a)
    Parent.GenServer.start_link(__MODULE__, {fun, opts}, gen_server_opts)
  end

  def start_link(fun),
    do: start_link({fun, []})

  def run!(fun, opts \\ []) do
    {:ok, result} = run(fun, opts)
    result
  end

  def run(fun, opts \\ []) do
    ref = make_ref()
    caller = self()
    fun = fn -> send(caller, {ref, fun.()}) end

    with {:ok, pid} <- start_link({fun, opts}) do
      mref = Process.monitor(pid)

      receive do
        {:DOWN, ^mref, :process, ^pid, reason} ->
          {:error, reason}

        {^ref, result} ->
          Process.demonitor(mref, [:flush])
          {:ok, result}
      end
    end
  end

  def start_task(fun, timeout \\ :infinity) do
    ref = make_ref()
    caller = self()
    fun = fn -> send(caller, {ref, fun.()}) end
    {:ok, pid} = start_aux(Parent.child_spec({Task, fun}, timeout: timeout))

    %{pid: pid, ref: ref}
  end

  def await_task(%{pid: pid, ref: ref}) do
    mref = Process.monitor(pid)

    receive do
      {:DOWN, ^mref, :process, ^pid, reason} ->
        {:error, reason}

      {^ref, result} ->
        Process.demonitor(mref, [:flush])
        {:ok, result}
    end
  end

  def start_os_cmd(cmd, opts \\ []) do
    case start_aux({OsCmd, {cmd, [notify: self()] ++ opts}}) do
      {:ok, pid} -> %{pid: pid, cmd: cmd}
      {:error, %OsCmd.Error{} = error} -> %{cmd: cmd, error: error}
    end
  end

  def await_os_cmd(%{error: error}), do: {:error, error.message}

  def await_os_cmd(cmd) do
    cmd.pid
    |> OsCmd.events()
    |> Stream.map(fn
      {:stopped, 0} -> :ok
      {:stopped, exit_status} -> {:error, exit_status}
      {:terminated, reason} -> {:error, reason}
      _other -> nil
    end)
    |> Enum.find(& &1)
  end

  def run_os_cmd(cmd, opts \\ []), do: cmd |> start_os_cmd(opts) |> await_os_cmd()

  def start_aux(child_spec) do
    Parent.Client.start_child(
      parent(),
      child_spec,
      id: nil,
      binds_to: [self()],
      restart: :temporary,
      ephemeral?: true
    )
  end

  defp parent, do: hd(Process.get(:"$ancestors"))

  @impl GenServer
  def init({fun, opts}) do
    Parent.start_child(
      {Task, fun},
      id: :main,
      restart: :temporary,
      ephemeral?: true,
      timeout: Keyword.get(opts, :timeout, :infinity)
    )

    {:ok, nil}
  end

  @impl Parent.GenServer
  def handle_stopped_children(%{main: %{exit_reason: reason}}, state),
    do: {:stop, reason, state}

  @impl Parent.GenServer
  def handle_stopped_children(_other, state),
    do: {:noreply, state}
end
