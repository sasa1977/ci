defmodule Job do
  use Parent.GenServer

  @type action ::
          (() -> response)
          | (responder -> {Parent.start_spec(), action_opts})
          | {module :: atom, function :: atom, args :: [any]}

  @type response :: any
  @type responder :: (response -> :ok)
  @type start_opts :: [
          respond_to: pid,
          timeout: timeout,
          name: GenServer.name(),
          telemetry_id: any,
          telemetry_meta: any
        ]
  @type action_opts :: [timeout: timeout, telemetry_id: any, telemetry_meta: any]

  @spec start_link(action, start_opts) :: GenServer.on_start()
  def start_link(action, opts \\ []) do
    {gen_server_opts, opts} = Keyword.split(opts, ~w/name/a)
    Parent.GenServer.start_link(__MODULE__, {action, opts}, gen_server_opts)
  end

  @spec child_spec({action, start_opts} | action) :: Parent.child_spec()
  def child_spec({action, opts}),
    do: Parent.parent_spec(id: __MODULE__, start: {__MODULE__, :start_link, [action, opts]})

  def child_spec(action), do: child_spec({action, []})

  @spec run(action, start_opts) :: response | {:exit, reason :: any}
  def run(action, opts \\ []) do
    with {:ok, pid} <- start_link(action, Keyword.merge(opts, respond_to: self())),
         do: await(pid)
  end

  @spec await(GenServer.server()) :: response | {:exit, reason :: any}
  def await(server) do
    pid = whereis!(server)
    mref = Process.monitor(pid)

    response =
      receive do
        {__MODULE__, :response, ^pid, response} -> response
      end

    receive do
      {:DOWN, ^mref, :process, ^pid, _} -> response
    end
  end

  @spec start_action(action, action_opts) :: Parent.on_start_child()
  def start_action(action, opts \\ []) do
    {action_spec, action_opts} = action_spec(action, responder(self()))
    opts = Keyword.merge(action_opts, opts)
    child_overrides = child_overrides(opts, self(), id: nil, binds_to: [self()])
    Parent.Client.start_child(parent(), action_spec, child_overrides)
  end

  @spec run_action(action, action_opts) :: response | {:exit, reason :: any}
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

  defp action_spec(fun, responder) when is_function(fun, 0), do: {task_spec(fun, responder), []}
  defp action_spec({_module, _fun, _args} = mfa, responder), do: {task_spec(mfa, responder), []}

  defp action_spec(fun, responder) when is_function(fun, 1) do
    {action_spec, action_opts} = fun.(responder)
    {Supervisor.child_spec(action_spec, []), action_opts}
  end

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
