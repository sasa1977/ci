defmodule OsCmd do
  use GenServer
  alias OsCmd.Faker

  defmodule Error do
    defexception [:message, :exit_status]
  end

  @type start_opts :: [
          name: GenServer.name(),
          handler: (event -> any),
          notify: pid(),
          timeout: pos_integer() | :infinity,
          cd: String.t(),
          env: [{String.t(), String.t()}],
          use_pty: boolean,
          terminate_cmd: String.t()
        ]

  @type event ::
          :starting
          | {:output, output}
          | {:stopped, exit_status}
          | {:terminated, reason :: any}

  @type mock ::
          String.t()
          | (command :: String.t(), start_opts -> {:ok, output} | {:error, exit_status, output})

  @type output :: String.t()
  @type exit_status :: non_neg_integer()

  @spec start_link(String.t()) :: GenServer.on_start()
  def start_link(command) when is_binary(command), do: start_link({command, []})

  @spec start_link({String.t(), start_opts}) :: GenServer.on_start()
  def start_link({command, opts}) do
    opts = normalize_opts(opts)
    GenServer.start_link(__MODULE__, {command, opts}, Keyword.take(opts, [:name]))
  end

  @spec stop(GenServer.name(), :infinity | pos_integer()) :: :ok
  def stop(server, timeout \\ :infinity) do
    pid = GenServer.whereis(server)
    mref = Process.monitor(pid)
    GenServer.cast(pid, :stop)

    receive do
      {:DOWN, ^mref, :process, ^pid, _reason} -> :ok
    after
      timeout -> exit(:timeout)
    end
  end

  @spec events(pid | {name, node} | name) :: Enumerable.t() when name: atom
  def events(server) do
    Stream.resource(
      fn -> Process.monitor(server) end,
      fn
        nil ->
          {:halt, nil}

        mref ->
          receive do
            {^server, {:stopped, _} = stopped} ->
              Process.demonitor(mref, [:flush])
              {[stopped], nil}

            {^server, message} ->
              {[message], mref}

            {:DOWN, ^mref, :process, ^server, reason} ->
              {[{:terminated, reason}], nil}
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
    start_arg = {cmd, [notify: self()] ++ opts}

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

  @spec await(pid | {name, node} | name) ::
          {:ok, output :: String.t()}
          | {:error, exit_status :: pos_integer() | term(), output :: String.t()}
        when name: atom
  def await(pid) do
    pid
    |> events()
    |> Enum.reduce(
      %{output: [], exit_status: nil},
      fn
        :starting, acc -> acc
        {:output, output}, acc -> update_in(acc.output, &[&1, output])
        {:stopped, exit_status}, acc -> %{acc | exit_status: exit_status}
        {:terminated, reason}, acc -> %{acc | exit_status: reason}
      end
    )
    |> case do
      %{exit_status: 0} = result -> {:ok, to_string(result.output)}
      result -> {:error, result.exit_status, to_string(result.output)}
    end
  end

  @spec allow(pid) :: :ok
  def allow(pid), do: Faker.allow(pid)

  @spec expect(mock) :: :ok
  def expect(fun), do: Faker.expect(fun)

  @spec stub(mock) :: :ok
  def stub(fun), do: Faker.stub(fun)

  @impl GenServer
  def init({cmd, opts}) do
    Process.flag(:trap_exit, true)

    Keyword.fetch!(opts, :handler).(:starting)

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
      {:ok, port} ->
        {:ok,
         %{
           port: port,
           handler: Keyword.fetch!(opts, :handler),
           propagate_exit?: Keyword.get(opts, :propagate_exit?, false),
           buffer: ""
         }}

      {:error, reason} ->
        {:stop, reason}
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

  def handle_info(:timeout, state), do: {:stop, :timeout, state}

  @impl GenServer
  def handle_continue({:stop, exit_status}, state) do
    state = invoke_handler(state, {:stopped, exit_status})
    exit_reason = if exit_status == 0, do: :normal, else: {:failed, exit_status}
    stop_server(%{state | port: nil}, exit_reason)
  end

  @impl GenServer
  def handle_cast(:stop, state), do: stop_server(state, :normal)

  @impl GenServer
  def terminate(_reason, %{port: nil}), do: :ok
  def terminate(_reason, state), do: stop_program(state)

  defp normalize_opts(opts) do
    all_handlers = Keyword.get_values(opts, :handler)
    all_subscribers = Keyword.get_values(opts, :notify)

    handler = fn message ->
      Enum.each(all_handlers, & &1.(message))
      Enum.each(all_subscribers, &send(&1, {self(), message}))
    end

    env =
      opts
      |> Keyword.get(:env, [])
      |> Enum.map(fn
        {name, nil} -> {to_charlist(name), false}
        {name, value} -> {to_charlist(name), to_charlist(value)}
      end)

    Keyword.merge(opts, handler: handler, env: env)
  end

  defp stop_server(%{propagate_exit?: false} = state, _exit_reason), do: {:stop, :normal, state}
  defp stop_server(state, reason), do: {:stop, reason, state}

  defp invoke_handler(%{handler: nil} = state, _message), do: state

  defp invoke_handler(%{handler: handler} = state, message) do
    message = with message when is_binary(message) <- message, do: :erlang.binary_to_term(message)
    {message, state} = normalize_message(message, state)
    handler.(message)
    state
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

  defp stop_program(%{port: port} = state) do
    Port.command(port, "stop")

    Stream.repeatedly(fn ->
      receive do
        {^port, {:data, message}} -> invoke_handler(state, message)
        {^port, {:exit_status, _exit_status}} -> nil
      end
    end)
    |> Enum.find(&is_nil/1)
  end

  @doc false
  def job_action_spec(responder, {cmd, opts}),
    do: {__MODULE__, {cmd, [handler: &handle_event(&1, cmd, responder)] ++ opts}}

  def job_action_spec(responder, cmd), do: job_action_spec(responder, {cmd, []})

  defp handle_event({:output, output}, _cmd, _responder),
    do: Process.put({__MODULE__, :output}, [Process.get({__MODULE__, :output}, []), output])

  defp handle_event({:stopped, exit_status}, cmd, responder) do
    output = to_string(Process.get({__MODULE__, :output}, []))

    response =
      if exit_status == 0 do
        {:ok, output}
      else
        message = "#{cmd} exited with status #{exit_status}:\n\n#{output}"
        {:error, %OsCmd.Error{exit_status: exit_status, message: message}}
      end

    responder.(response)
  end

  defp handle_event(_event, _cmd, _caller), do: :ok

  defmodule Program do
    @moduledoc false
    @type id :: any

    @callback start(cmd :: String.t() | [String.t()], opts :: Keyword.t()) ::
                {:ok, id} | {:error, reason :: any}
  end
end
