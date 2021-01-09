defmodule Job do
  use Parent.GenServer

  def start_link(action, opts \\ []) do
    {gen_server_opts, opts} = Keyword.split(opts, ~w/name/a)

    opts =
      opts
      |> Keyword.pop(:respond?, false)
      |> case do
        {false, _opts} -> opts
        {true, opts} -> Keyword.merge(opts, respond_to: self())
      end
      |> Enum.into(%{timeout: :timer.seconds(5), respond_to: nil})

    Parent.GenServer.start_link(__MODULE__, {action, opts}, gen_server_opts)
  end

  @doc false
  def child_spec({action, opts}),
    do: Parent.parent_spec(id: __MODULE__, start: {__MODULE__, :start_link, [action, opts]})

  def child_spec(action), do: child_spec({action, []})

  def run(action, opts \\ []) do
    with {:ok, pid} <- start_link(action, Keyword.merge(opts, respond?: true)),
         do: await(pid)
  end

  def await(pid) do
    receive do
      {__MODULE__, :response, ^pid, response} -> response
    end
  end

  def start_action(action, opts \\ []) do
    Parent.Client.start_child(
      parent(),
      action_spec(action, responder(self())),
      id: nil,
      binds_to: [self()],
      restart: :temporary,
      ephemeral?: true,
      timeout: Keyword.get(opts, :timeout, :timer.seconds(5)),
      meta: %{respond_to: self()}
    )
  end

  def run_action(action, opts \\ []) do
    with {:ok, pid} <- start_action(action, opts),
         do: await(pid)
  end

  def respond(pid, response), do: respond(pid, response, [])

  @impl GenServer
  def init({action, opts}) do
    case Parent.start_child(
           action_spec(action, responder(opts.respond_to, from: self())),
           id: :main,
           restart: :temporary,
           ephemeral?: true,
           timeout: opts.timeout,
           meta: %{respond_to: opts.respond_to}
         ) do
      {:ok, _pid} -> {:ok, opts}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl Parent.GenServer
  def handle_stopped_children(%{main: %{exit_reason: reason, meta: meta}}, state) do
    send_exit_response(self(), reason, meta)
    exit_reason = if is_nil(state.respond_to), do: reason, else: :normal
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
  defp action_spec(fun, responder) when is_function(fun, 1), do: fun.(responder)
  defp action_spec({module, arg}, responder), do: module.job_action_spec(responder, arg)

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
end
