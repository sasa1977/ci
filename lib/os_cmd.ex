defmodule OsCmd do
  use GenServer
  alias OsCmd.Faker

  defmodule Error do
    defexception [:message, :exit_status, :output]
  end

  @type start_opts :: [
          name: GenServer.name(),
          handler: handler,
          timeout: pos_integer() | :infinity,
          cd: String.t(),
          env: [{String.t() | atom, String.t() | nil}],
          use_pty: boolean,
          terminate_cmd: String.t(),
          telemetry_id: any,
          telemetry_meta: any
        ]

  @type handler :: (event -> any) | {acc, (event, acc -> acc)}
  @type acc :: any

  @type event ::
          :starting
          | {:output, output}
          | {:stopped, exit_status}

  @type mock ::
          String.t()
          | (command :: String.t(), start_opts -> {:ok, output} | {:error, exit_status, output})

  @type output :: String.t()
  @type exit_status :: non_neg_integer() | (exit_reason :: :timeout | any)

  @spec start_link(String.t()) :: GenServer.on_start()
  def start_link(command) when is_binary(command), do: start_link({command, []})

  @spec start_link({String.t(), start_opts}) :: GenServer.on_start()
  def start_link({command, opts}) do
    opts = normalize_opts(opts)
    GenServer.start_link(__MODULE__, {command, opts}, Keyword.take(opts, [:name]))
  end

  @spec stop(GenServer.server(), :infinity | pos_integer()) :: :ok
  def stop(server, timeout \\ :infinity) do
    pid = whereis!(server)
    mref = Process.monitor(pid)
    GenServer.cast(pid, :stop)

    receive do
      {:DOWN, ^mref, :process, ^pid, _reason} -> :ok
    after
      timeout -> exit(:timeout)
    end
  end

  @spec events(GenServer.server()) :: Enumerable.t()
  def events(server) do
    pid = GenServer.whereis(server)

    Stream.resource(
      fn -> Process.monitor(pid) end,
      fn
        nil ->
          {:halt, nil}

        mref ->
          receive do
            {^pid, {:stopped, _} = stopped} ->
              Process.demonitor(mref, [:flush])
              {[stopped], nil}

            {^pid, message} ->
              {[message], mref}

            {:DOWN, ^mref, :process, ^pid, reason} ->
              {[{:stopped, reason}], nil}
          end
      end,
      fn
        nil -> :ok
        mref -> Process.demonitor(mref, [:flush])
      end
    )
  end

  @spec run(String.t(), start_opts()) :: {:ok, output} | {:error, exit_status | term(), output}
  def run(cmd, opts \\ []) do
    caller = self()
    start_arg = {cmd, [handler: &send(caller, {self(), &1})] ++ opts}

    start_fun =
      case Keyword.fetch(opts, :start) do
        :error -> fn -> start_link(start_arg) end
        {:ok, fun} -> fn -> fun.({__MODULE__, start_arg}) end
      end

    with {:ok, pid} <- start_fun.() do
      try do
        await(pid)
      after
        stop(pid)
      end
    end
  end

  @spec await(GenServer.server()) ::
          {:ok, output :: String.t()}
          | {:error, exit_status :: pos_integer() | term(), output :: String.t()}
  def await(server) do
    server
    |> whereis!()
    |> events()
    |> Enum.reduce(
      %{output: [], exit_status: nil},
      fn
        :starting, acc -> acc
        {:output, output}, acc -> update_in(acc.output, &[&1, output])
        {:stopped, exit_status}, acc -> %{acc | exit_status: exit_status}
      end
    )
    |> case do
      %{exit_status: 0} = result -> {:ok, to_string(result.output)}
      result -> {:error, result.exit_status, to_string(result.output)}
    end
  end

  @spec action(String.t(), start_opts) :: Job.action()
  def action(cmd, opts \\ []) do
    fn responder ->
      handler_state = %{responder: responder, cmd: cmd, opts: opts, output: []}

      action_opts =
        Keyword.merge(
          [telemetry_meta: %{cmd: cmd}],
          Keyword.take(opts, ~w/telemetry_id/a)
        )

      {{__MODULE__, {cmd, [handler: {handler_state, &handle_event/2}] ++ opts}}, action_opts}
    end
  end

  @spec allow(GenServer.server()) :: :ok
  def allow(server), do: Faker.allow(whereis!(server))

  @spec expect(mock) :: :ok
  def expect(fun), do: Faker.expect(fun)

  @spec stub(mock) :: :ok
  def stub(fun), do: Faker.stub(fun)

  @impl GenServer
  def init({cmd, opts}) do
    Process.flag(:trap_exit, true)

    state = %{
      port: nil,
      handlers: Keyword.fetch!(opts, :handlers),
      propagate_exit?: Keyword.get(opts, :propagate_exit?, false),
      buffer: "",
      exit_reason: nil
    }

    state = invoke_handler(state, :starting)

    with {:ok, timeout} <- Keyword.fetch(opts, :timeout),
         do: Process.send_after(self(), :timeout, timeout)

    starter =
      case Faker.fetch() do
        {:ok, pid} ->
          Mox.allow(Faker.Port, pid, self())
          Faker.Port

        :error ->
          OsCmd.Port
      end

    case starter.start(cmd, opts) do
      {:ok, port} -> {:ok, %{state | port: port}}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_info({port, {:exit_status, exit_status}}, %{port: port} = state),
    # Delegating to `handle_continue` because we must invoke a custom handler which can crash, so
    # we need to make sure that the correct state is committed.
    do: {:noreply, %{state | port: nil}, {:continue, {:stop, exit_status}}}

  def handle_info({port, {:data, message}}, %{port: port} = state) do
    state = invoke_handler(state, message)
    {:noreply, state}
  end

  def handle_info(:timeout, state) do
    send_stop_command(state)
    {:noreply, %{state | exit_reason: :timeout}}
  end

  @impl GenServer
  def handle_continue({:stop, exit_status}, state) do
    state = invoke_handler(state, {:stopped, exit_status})

    exit_reason =
      cond do
        not is_nil(state.exit_reason) -> state.exit_reason
        not state.propagate_exit? or exit_status == 0 -> :normal
        true -> {:failed, exit_status}
      end

    {:stop, exit_reason, %{state | port: nil}}
  end

  @impl GenServer
  def handle_cast(:stop, state) do
    send_stop_command(state)
    {:noreply, %{state | exit_reason: :normal}}
  end

  @impl GenServer
  def terminate(_reason, %{port: port} = state) do
    unless is_nil(port) do
      send_stop_command(state)

      receive do
        {^port, {:exit_status, _exit_status}} -> :ok
      end
    end
  end

  defp normalize_opts(opts) do
    {handlers, opts} = Keyword.pop_values(opts, :handler)

    env =
      opts
      |> Keyword.get(:env, [])
      |> Enum.map(fn
        {name, nil} -> {env_name_to_charlist(name), false}
        {name, value} -> {env_name_to_charlist(name), to_charlist(value)}
      end)

    Keyword.merge(opts, handlers: handlers, env: env)
  end

  defp env_name_to_charlist(atom) when is_atom(atom),
    do: atom |> to_string() |> String.upcase() |> to_charlist()

  defp env_name_to_charlist(name), do: to_charlist(name)

  defp invoke_handler(state, message) do
    message = with message when is_binary(message) <- message, do: :erlang.binary_to_term(message)
    {message, state} = normalize_message(message, state)

    handlers =
      Enum.map(
        state.handlers,
        fn
          {acc, fun} ->
            {fun.(message, acc), fun}

          fun ->
            fun.(message)
            fun
        end
      )

    %{state | handlers: handlers}
  end

  defp normalize_message({:output, output}, state) do
    {output, rest} = get_utf8_chars(state.buffer <> output)
    {{:output, to_string(output)}, %{state | buffer: rest}}
  end

  defp normalize_message(message, state), do: {message, state}

  defp get_utf8_chars(<<char::utf8, rest::binary>>) do
    {remaining_bytes, rest} = get_utf8_chars(rest)
    {[char | remaining_bytes], rest}
  end

  defp get_utf8_chars(other), do: {[], other}

  defp send_stop_command(state) do
    if not is_nil(state.port) do
      try do
        Port.command(state.port, "stop")
      catch
        _, _ -> :ok
      end
    end
  end

  defp handle_event({:output, output}, state),
    do: update_in(state.output, &[&1, output])

  defp handle_event({:stopped, exit_status}, state) do
    output = to_string(state.output)

    response =
      if exit_status == 0 do
        {:ok, output}
      else
        message = "#{state.cmd} exited with status #{exit_status}"
        {:error, %OsCmd.Error{exit_status: exit_status, message: message, output: output}}
      end

    state.responder.(response)
    nil
  end

  defp handle_event(_event, state), do: state

  defp whereis!(server) do
    case GenServer.whereis(server) do
      pid when is_pid(pid) -> pid
      nil -> raise "process #{inspect(server)} not found"
    end
  end

  defmodule Program do
    @moduledoc false
    @type id :: any

    @callback start(cmd :: String.t() | [String.t()], opts :: Keyword.t()) ::
                {:ok, id} | {:error, reason :: any}
  end
end
