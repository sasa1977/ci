defmodule OsCmd do
  @moduledoc """
  Managed execution of external commands.

  This module provides similar functionality to `System.cmd/3`, with the difference that the
  execution of commands is managed, which provides the following benefits:

  1. The external OS process is logically linked to the parent BEAM process (the process which
     started it). If the parent process terminates, the OS process will be taken down.
  2. The external OS process will also be taken down if the entire BEAM instance goes down.
  3. Support for timeout-based and manual termination of the OS process.
  4. Polite-first termination of the OS process (SIGTERM followed by SIGKILL) in the spirit of
     OTP termination (shutdown strategies).

  In this regard, `OsCmd` is similar to [erlexec](http://saleyn.github.io/erlexec/) and
  [porcelain](https://github.com/alco/porcelain), though it doesn't have all the features of those
  projects.

  For usage details, see `start_link/1`.
  """

  defmodule Error do
    @moduledoc "Error struct returned by various OsCmd operations."

    @type t :: %__MODULE__{message: String.t(), exit_status: term, output: String.t()}

    defexception [:message, :exit_status, :output]
  end

  use GenServer, shutdown: :infinity
  alias OsCmd.Faker

  @type start_opt ::
          {:name, GenServer.name()}
          | {:handler, handler}
          | {:timeout, pos_integer() | :infinity}
          | {:cd, String.t()}
          | {:env, [{String.t() | atom, String.t() | nil}]}
          | {:pty, boolean}
          | {:propagate_exit?, boolean}
          | {:terminate_cmd, String.t()}

  @type handler :: (event -> any) | {acc, (event, acc -> acc)}
  @type acc :: any

  @type event ::
          :starting
          | {:output, output}
          | {:stopped, exit_status}

  @type mock ::
          String.t()
          | (command :: String.t(), [start_opt] -> {:ok, output} | {:error, Error.t()})

  @type output :: String.t()
  @type exit_status :: non_neg_integer() | (exit_reason :: :timeout | any)

  @doc """
  Starts the command owner process.

  The owner process will start the command, handle its events, and stop when the command finishes.
  The started process will synchronously stop the command during while being terminated. The owner
  process never stops before the command finishes (unless the owner process is forcefully
  terminated with the reason `:kill`), which makes it safe to run under a supervisor or `Parent`.

  The command is a "free-form string" in the shape of: `"command arg1 arg2 ..."`. The command has
  to be an executable that exists in standard search paths.

  Args can be separated by one or more whitespaces, tabs, or newline characters. If any arg has
  to contain whitespace characters, you can encircle it in double or single quotes. Inside the
  quoted argument, you can use `\\"` or `\\'` to inject the quote character, and `\\\\` to inject
  the backslash character.

  Examples:

      OsCmd.start_link("echo 1")`

      OsCmd.start_link(~s/
        some_cmd
          arg1
          "arg \\" \\\\ 2"
          'arg \\' \\\\ 3'
      /)

  Due to support for free-form execution, it is possible to execute complex scripts, by starting
  the shell process

      OsCmd.start_link(~s/bash -c "..."/)

  However, this is usually not advised, because `OsCmd` can't keep all of its guarantees. Any
  child process started inside the shell is not guaranteed to be terminated before the owner
  process stops, and some of them might even linger on forever.

  ## Options

  You can pass additional options by invoking `OsCmd.start_link({cmd, opts})`. The following
  options are supported:

    - `:cd` - Folder in which the command will be started
    - `:env`- OS environment variables which will be set in the command's own environment. Note
      that the command OS process inherits the environment from the BEAM process. If you want to
      unset some of the inherited variables, you can include `{var_to_unset, nil}` in this list.
    - `:pty` - If set to `true`, the command will be started with a pseudo-terminal interface.
      If the OS doesn't support pseudo-terminal, this flag is ignored. Defaults to `false`.
    - `:timeout` - The duration after which the command will be automatically terminated.
      Defaults to `:infinity`. If the command is timed out, the process will exit with the reason
      `:timeout`, irrespective of the `propagate_exit?` setting.
    - `propagate_exit?` - When set to `true` and the exit reason of the command is not zero, the
      process will exit with `{:failed, exit_status}`. Otherwise, the process will always exit
      with the reason `:normal` (unless the command times out).
    - `terminate_cmd` - Custom command to use in place of SIGTERM when stopping the OS process.
      See the "Command termination" section for details.
    - `handler` - Custom event handler. See the "Event handling" section for details.
    - `name` - Registered name of the process. If not provided, the process won't be registered.

  ## Event handling

  During the lifetime of the command, the following events are emitted:

    - `:starting` - the command is being started
    - `{:output, output}` - stdout or stderr output
    - `{:stopped, exit_status}` - the command stopped with the given exit status

  You can install multiple custom handlers to deal with these events. By default, no handler is
  created, which means that the command is executed silently. Handlers are functions which are
  executed inside the command owner process. Handlers can be stateless or stateful.

  A stateless handler is a function in the shape of `fun(event) -> ... end`. This function holds
  no state, so its result is ignored. A stateful handler can be specified as
  `{initial_acc, fun(event, acc) -> next_acc end}`. You can provide multiple handlers, and they
  don't have to be of the same type.

  Since handlers are executed in the owner process, an unhandled exception in the handler will
  lead to process termination. The OS process will be properly taken down before the owner process
  stops, but no additional event (including the `:stopped` event) will be fired.

  It is advised to minimize the logic inside handlers. Handlers are best suited for very simple
  tasks such as logging or notifying other processes.

  ### Output

  The output events will contain output fragments, as they are received. It is therefore possible
  that some fragment contains only a part of the output line, while another spans multiple lines.
  It is the responsibility of the client to assemble these fragments according to its needs.

  `OsCmd` operates on the assumption that output is in utf8 encoding, so it may not work correctly
  for other encodings, such as plain binary.

  ## Command termination

  When command is being externally terminated (e.g. due to a timeout), a polite termination is
  first attempted, by sending a SIGTERM signal to the OS process (if the OS supports such signal),
  or alternatively invoking a custom terminated command provided via `:terminate_cmd`. If the OS
  process doesn't stop in 5 seconds (currently not configurable), a SIGKILL signal will be sent.

  ## Internals

  The owner process starts the command as the Erlang port. The command is not started directly.
  Instead a bridge program (implemented in go) is used to start and manage the OS process. Each
  command uses its own bridge process. This approach ensures proper cleanup guarantees even if the
  BEAM OS process is taken down.

  As a result, compared to `System.cmd/3`, `OsCmd` will consume more resources (2x more OS process
  instances) and require more hops to pass the output back to Elixir. Most often this won't matter,
  but be aware of these trade-offs if you're starting a large number of external processes.

  ## Mocking in tests

  Command execution can be mocked, which may be useful if you want to avoid starting long-running
  commands in tests.

  Mocking can done with `expect/1` and `stub/1`, and explicit allowances can be issued with
  `allow/1`.
  """
  @spec start_link(String.t()) :: GenServer.on_start()
  def start_link(command) when is_binary(command), do: start_link({command, []})

  @spec start_link({String.t(), [start_opt]}) :: GenServer.on_start()
  def start_link({command, opts}) do
    opts = normalize_opts(opts)
    GenServer.start_link(__MODULE__, {command, opts}, Keyword.take(opts, [:name]))
  end

  @doc "Stops the command and the owner process."
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

  @doc """
  Returns a lazy stream of events.

  This function is internally used by `run/2` and `await/1`. If you want to use it yourself, you
  need to pass the handler `&send(some_pid, {self(), &1})` when starting the command. This
  function can only be invoked in the process which receives the event messages.
  """
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

  @doc """
  Synchronously runs the command.

  This function will start the owner process, wait for it to finish, and return the result which
  will include the complete output of the command.

  If the command exits with a zero exit status, an `:ok` tuple is returned. Otherwise, the function
  returns an error tuple.

  See `start_link/1` for detailed explanation.
  """
  @spec run(String.t(), [start_opt]) :: {:ok, output} | {:error, Error.t()}
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

  @doc """
  Awaits for the started command to finish.

  This function is internally used by `run/2`. If you want to use it yourself, you need to pass the
  handler `&send(some_pid, {self(), &1})` when starting the command. This function can only be
  invoked in the process which receives the event messages.
  """
  @spec await(GenServer.server()) :: {:ok, output :: String.t()} | {:error, Error.t()}
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
      %{exit_status: 0} = result ->
        {:ok, to_string(result.output)}

      result ->
        {
          :error,
          %Error{
            message: "command failed",
            output: to_string(result.output),
            exit_status: result.exit_status
          }
        }
    end
  end

  @doc """
  Returns a specification for running the command as a `Job` action.

  The corresponding action will return `{:ok, output} | {:error, %OsCmdError{}}`
  See `Job.start_action/2` for details.
  """
  @spec action(String.t(), [start_opt | Job.action_opt()]) :: Job.action()
  def action(cmd, opts \\ []) do
    fn responder ->
      {action_opts, opts} = Keyword.split(opts, ~w/telemetry_id temeletry_meta/a)
      action_opts = Config.Reader.merge(action_opts, telemetry_meta: %{cmd: cmd})
      handler_state = %{responder: responder, cmd: cmd, opts: opts, output: []}
      {{__MODULE__, {cmd, [handler: {handler_state, &handle_event/2}] ++ opts}}, action_opts}
    end
  end

  @doc """
  Issues an explicit mock allowance to another process.

  Note that mocks are automatically inherited by descendants, so you only need to use this for non
  descendant processes. See `Mox.allow/3` for details.
  """
  @spec allow(GenServer.server()) :: :ok
  def allow(server), do: Faker.allow(whereis!(server))

  @doc """
  Sets up a mock expectation.

  The argument can be either a string (the exact command text), or a function. If the string is
  passed, the mocked command will succeed with the empty output. If the function is passed, it will
  be invoked when the command is started. The function can then return ok or error tuple.

  The expectation will be inherited by all descendant processes (unless overridden somewhere down
  the process tree).

  See `Mox.expect/4` for details on expectations.
  """
  @spec expect(mock) :: :ok
  def expect(fun), do: Faker.expect(fun)

  @doc """
  Sets up a mock stub.

  This function works similarly to `expect/1`, except it sets up a stub. See `Mox.stub/3` for
  details on stubs.
  """
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

      # If we end up here, we still didn't receive the exit_status command, so we'll await for it
      # indefinitely. We assume that the go bridge works flawlessly and that it will stop the
      # program eventually, so there's no timeout clause. If there's a bug, this process will hang,
      # but at least we won't leak OS processes.
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
        {:error, %Error{exit_status: exit_status, message: message, output: output}}
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
