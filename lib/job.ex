defmodule Job do
  use Parent.GenServer

  @type action ::
          (() -> response)
          | {module :: atom, function :: atom, args :: [any]}
          | (responder -> Parent.start_spec())
          | {module :: atom, arg :: any}

  @type response :: any
  @type responder :: (response -> :ok)

  @type start_opts :: [respond_to: pid, timeout: timeout, name: GenServer.name()]

  @spec start_link(action, start_opts) :: GenServer.on_start()
  def start_link(action, opts \\ []) do
    {gen_server_opts, opts} = Keyword.split(opts, ~w/name/a)

    opts =
      opts
      |> Keyword.pop(:respond?, false)
      |> case do
        {false, _opts} -> opts
        {true, opts} -> Keyword.merge(opts, respond_to: self())
      end

    Parent.GenServer.start_link(__MODULE__, {action, opts}, gen_server_opts)
  end

  @spec child_spec({action, start_opts} | action) :: Parent.child_spec()
  def child_spec({action, opts}),
    do: Parent.parent_spec(id: __MODULE__, start: {__MODULE__, :start_link, [action, opts]})

  def child_spec(action), do: child_spec({action, []})

  @spec run(action, start_opts) :: response | {:exit, reason :: any}
  def run(action, opts \\ []) do
    with {:ok, pid} <- start_link(action, Keyword.merge(opts, respond?: true)),
         do: await(pid)
  end

  @spec await(GenServer.server()) :: response | {:exit, reason :: any}
  def await(server) do
    pid = whereis!(server)

    receive do
      {__MODULE__, :response, ^pid, response} -> response
    end
  end

  @spec start_action(action, timeout: timeout) :: Parent.on_start_child()
  def start_action(action, opts \\ []) do
    action_spec = action_spec(action, responder(self()))
    child_overrides = child_overrides(opts, self(), id: nil, binds_to: [self()])
    Parent.Client.start_child(parent(), action_spec, child_overrides)
  end

  @spec run_action(action, timeout: timeout) :: response | {:exit, reason :: any}
  def run_action(action, opts \\ []) do
    with {:ok, pid} <- start_action(action, opts),
         do: await(pid)
  end

  @impl GenServer
  def init({action, opts}) do
    {respond_to, opts} = Keyword.pop(opts, :respond_to)
    action_spec = action_spec(action, responder(respond_to, from: self()))
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

  defp action_spec(fun, responder) when is_function(fun, 0), do: task_spec(fun, responder)
  defp action_spec({_module, _fun, _args} = mfa, responder), do: task_spec(mfa, responder)

  defp action_spec(fun, responder) when is_function(fun, 1),
    do: Supervisor.child_spec(fun.(responder), [])

  defp action_spec({module, arg}, responder),
    do: Supervisor.child_spec(module.job_action_spec(responder, arg), [])

  defp task_spec(invocable, responder), do: {Task, fn -> responder.(invoke(invocable)) end}

  defp invoke(fun) when is_function(fun, 0), do: fun.()
  defp invoke({module, function, args}), do: apply(module, function, args)

  defp send_exit_response(from, reason, meta),
    do: if(reason != :normal, do: respond(meta.respond_to, {:exit, reason}, from: from))

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
    [timeout: :timer.seconds(5)]
    |> Keyword.merge(overrides)
    |> Keyword.merge(extra_overrides)
    |> Keyword.merge(meta: %{respond_to: respond_to}, restart: :temporary, ephemeral?: true)
  end

  defp whereis!(server) do
    case GenServer.whereis(server) do
      pid when is_pid(pid) -> pid
      nil -> raise "process #{inspect(server)} not found"
    end
  end
end
