defmodule Job do
  @moduledoc """
  Managed execution of potentially failing actions.

  A job is a logical unit of work which is split into multiple _actions_, where each action is
  running in its own separate process, which is a child of the job process.

  ## Basic sketch

      Job.start_link(fn ->
        # this is the root action

        {:ok, action1} = Job.start_action(fn ->
          # ...
        end)

        {:ok, action2} = Job.start_action(fn ->
          result_of_action_3 =
            Job.run(fn ->

            end)

          # ...
        end)

        {Job.await(action1), Job.await(action2)}
      end)

  ## Comparison to tasks

  Job is somewhat similar to `Task`, with the main difference that it manages the execution of its
  actions. The job process stops only after all of its actions have terminated, which is a
  guarantee not provided by `Task`.

  In addition, `Job` makes some different decisions. Most notably, a crash of an action is
  automatically converted into an error result, which simplifies the implementation of custom crash
  logic (e.g. error reporting).

  If slight asynchronism during termination can be tolerated, and there's no need to implement
  custom crash logic, `Task` is likely a better option.

  ## Actions

  Each job runs one or more actions, which are technically child processes of the job process.
  A job is started with the _root action_. When the root action stops, the job process will also
  stop with the same exit reason. This is the only case where `Job` propagates a process exit.

  In its simplest form, an action can be a zero-arity function or an MFA tuple. In both cases,
  the action process will be powered by `Task`. You can also power the action process by your own
  module. See "Custom action processes" for details.

  Each action can start additional actions. Logically, such action is treated as the child of
  the action which started it. If the parent action terminates, its children will also be taken
  down.

  Technically every action process will be running as a direct child of the job process. This
  decision is made to simplify the process tree and reduce the amount of running processes.

  You can start additional actions with `start_action/2` or `run_action/2`. If `start_action/2` is
  used, the action result can be awaited on with `await/1`. These functions may only be invoked
  inside an action process.

  In case of `Task`-powered jobs, the action result is the return value of the invoked function. If
  the action process crashes, the result will be `{:exit, exit_reason}`. To avoid ambiguity, it is
  recommended to return ok/error tuples from the actions.

  ## Custom action processes

  To power the action by a custom logic (e.g. `GenServer`), you need to provide the action
  spec factory function to `start_action/2` or `run_action/2`:

      Job.start_action(
        fn responder ->
          child_spec(responder)
        end
      )

  The factory function takes the responder, which is an arity one anonymous function. The function
  should return a child specification (`t:Parent.start_spec/0`) which describes how to start the
  action process.

  The action process needs to invoke `responder.(action_response)` to send the response back to
  its caller. This function may only be invoked inside the action process. As soon as this function
  is invoked, the action process must stop with the reason `:normal`.

  If the action process is stopping with an abnormal exit reason, it shouldn't invoke the responder
  function. Doing this will lead to duplicate response message in the mailbox of the parent action.

  For example of custom actions, see `OsCmd` and `Job.Pipeline`.

  ## Internals

  The job process is powered by `Parent`, with all actions running as its children. Logical
  hierarchy (parent-child relationship between actions) is modeled via bound siblings feature
  of `Parent`.
  """

  use Parent.GenServer

  @type action ::
          action_fun_or_mfa
          | {action_fun_or_mfa, [action_opt]}
          | (responder -> {Parent.start_spec(), [action_opt]})

  @type action_fun_or_mfa :: (() -> response) | {module :: atom, function :: atom, args :: [any]}

  @type response :: any
  @type responder :: (response -> :ok)
  @type start_opt :: {:respond_to, pid} | {:name, GenServer.name()} | action_opt
  @type action_opt :: {:timeout, timeout} | {:telemetry_id, [any]} | {:telemetry_meta, map}

  @doc """
  Starts the job process and the root action.

  ## Options

    - `:respond_to` - a pid of the process that will receive the result of the root action.
      The target process can await on the result with `await/1`. If this option is not provided,
      the response will not be sent.
    - `name` - Registered name of the process. If not provided, the process won't be registered.
    - action option - see `start_action/2` for details.
  """
  @spec start_link(action, [start_opt]) :: GenServer.on_start()
  def start_link(action, opts \\ []) do
    {gen_server_opts, opts} = Keyword.split(opts, ~w/name/a)
    Parent.GenServer.start_link(__MODULE__, {action, opts}, gen_server_opts)
  end

  @doc "Returns a child specification for inserting a job into the supervision tree."
  @spec child_spec({action, [start_opt]} | action) :: Parent.child_spec()
  def child_spec({action, opts}),
    do: Parent.parent_spec(id: __MODULE__, start: {__MODULE__, :start_link, [action, opts]})

  def child_spec(action), do: child_spec({action, []})

  @doc "Starts the job with `start_link/2`, and awaits for it with `await/1`."
  @spec run(action, [start_opt]) :: response | {:exit, reason :: any}
  def run(action, opts \\ []) do
    with {:ok, pid} <- start_link(action, Keyword.merge(opts, respond_to: self())),
         do: await(pid)
  end

  @doc """
  Awaits for the job or the action response.

  This function must be invoked in the process which receives the response message. In the case of
  the job, this is the process specified with the `:respond_to` start option. When awaiting on the
  action, this is the logical parent action (i.e. the process that started the action).

  This function will await indefinitely. There's no support for client-side timeout. Instead, you
  can use the `:timeout` action option to limit the duration of an action.

  If the awaited job or action crashes, the response will be `{:exit, exit_reason}`. To avoid
  ambiguity, it is recommended to return ok/error tuples from each action.
  """
  @spec await(GenServer.server()) :: response | {:exit, reason :: any}
  def await(server) do
    pid = whereis!(server)
    mref = Process.monitor(pid)

    # We assume that response will always be sent. This is ensured by the parent logic which
    # sends the response in the `handle_stopped_children` callback.
    response =
      receive do
        {__MODULE__, :response, ^pid, response} -> response
      end

    # Awaiting for the process to stop before returning the response to improve synchronism.
    receive do
      {:DOWN, ^mref, :process, ^pid, _} -> response
    end
  end

  @doc """
  Starts a child action.

  See module documentation for details on action specification.

  The started action process will logically be treated as the child of the caller process. If the
  caller process terminates, the started process will be taken down as well.

  Unlike the root action, a child action always sends response to its caller. You can await this
  response with `await/1`.

  This function can only be invoked inside an action process.

  ## Options

    - `:timeout` - Maximum duration of the action. If the action exceeds the given duration, it
      will be forcefully taken down. Defaults to `:infinity`.
    - `:telemetry_id` - If provided, telemetry start and stop events will be emitted. This option
      must be a list. Job will append `:start` and `:stop` atoms to this list to emit the events.
    - `:telemetry_meta` - Additional metadata to send with telemetry events. If not provided, an
      empty map is used.
  """
  @spec start_action(action, [action_opt]) :: Parent.on_start_child()
  def start_action(action, opts \\ []) do
    {action_spec, action_opts} = action_spec(action, responder(self()))
    opts = Keyword.merge(action_opts, opts)
    child_overrides = child_overrides(opts, self(), id: nil, binds_to: [self()])
    Parent.Client.start_child(parent(), action_spec, child_overrides)
  end

  @doc "Starts a child action and awaits for its response."
  @spec run_action(action, [action_opt]) :: response | {:exit, reason :: any}
  def run_action(action, opts \\ []) do
    with {:ok, pid} <- start_action(action, opts),
         do: await(pid)
  end

  @impl GenServer
  def init({action, opts}) do
    {respond_to, opts} = Keyword.pop(opts, :respond_to)
    {action_spec, action_opts} = action_spec(action, responder(respond_to, from: self()))
    opts = Keyword.merge(action_opts, opts)
    child_overrides = child_overrides(opts, respond_to, id: :main)

    case Parent.start_child(action_spec, child_overrides) do
      {:ok, _pid} -> {:ok, nil}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl Parent.GenServer
  def handle_stopped_children(%{main: %{exit_reason: reason, meta: meta}}, state) do
    send_exit_response(self(), reason, meta)
    exit_reason = if is_nil(meta.respond_to), do: reason, else: :normal
    {:stop, exit_reason, state}
  end

  @impl Parent.GenServer
  def handle_stopped_children(other, state) do
    Enum.each(
      other,
      fn {pid, %{exit_reason: reason, meta: meta}} -> send_exit_response(pid, reason, meta) end
    )

    {:noreply, state}
  end

  defp action_spec(fun, responder) when is_function(fun, 1) do
    {action_spec, action_opts} = fun.(responder)
    {Supervisor.child_spec(action_spec, []), action_opts}
  end

  defp action_spec({fun_or_mfa, action_opts}, responder),
    do: {task_spec(fun_or_mfa, responder), action_opts}

  defp action_spec(fun_or_mfa, responder), do: action_spec({fun_or_mfa, []}, responder)

  defp task_spec(invocable, responder), do: {Task, fn -> responder.(invoke(invocable)) end}

  defp invoke(fun) when is_function(fun, 0), do: fun.()
  defp invoke({module, function, args}), do: apply(module, function, args)

  defp send_exit_response(from, reason, meta) do
    unless is_nil(meta.telemetry_id) do
      duration = System.monotonic_time() - meta.start

      :telemetry.execute(
        meta.telemetry_id ++ [:stop],
        %{duration: duration},
        meta.telemetry_meta
      )
    end

    if(reason != :normal, do: respond(meta.respond_to, {:exit, reason}, from: from))
  end

  defp parent, do: hd(Process.get(:"$ancestors"))

  defp responder(respond_to, opts \\ []),
    do: &respond(respond_to, &1, opts)

  defp respond(server, response, opts) do
    with server when not is_nil(server) <- server,
         pid when not is_nil(pid) <- GenServer.whereis(server),
         do: send(pid, {__MODULE__, :response, Keyword.get(opts, :from, self()), response})

    :ok
  end

  defp child_overrides(overrides, respond_to, extra_overrides) do
    start = System.monotonic_time()
    telemetry_id = Keyword.get(overrides, :telemetry_id)
    telemetry_meta = Keyword.get(overrides, :telemetry_meta, %{})

    unless is_nil(telemetry_id),
      do: :telemetry.execute(telemetry_id ++ [:start], %{time: start}, telemetry_meta)

    meta = %{
      respond_to: respond_to,
      start: start,
      telemetry_id: telemetry_id,
      telemetry_meta: telemetry_meta
    }

    [timeout: :timer.seconds(5)]
    |> Keyword.merge(overrides)
    |> Keyword.merge(extra_overrides)
    |> Keyword.merge(meta: meta, restart: :temporary, ephemeral?: true)
  end

  defp whereis!(server) do
    case GenServer.whereis(server) do
      pid when is_pid(pid) -> pid
      nil -> raise "process #{inspect(server)} not found"
    end
  end
end
