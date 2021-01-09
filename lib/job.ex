defmodule Job do
  use Parent.GenServer

  def start_link(root_action, opts) do
    start_link({root_action, opts})
  end

  def start_link({root_action, opts}) do
    {gen_server_opts, opts} = Keyword.split(opts, ~w/name/a)

    opts =
      opts
      |> Keyword.pop(:respond?, false)
      |> case do
        {false, _opts} -> opts
        {true, opts} -> Keyword.merge(opts, respond_to: self())
      end
      |> Enum.into(%{timeout: :timer.seconds(5), respond_to: nil})

    Parent.GenServer.start_link(__MODULE__, {root_action, opts}, gen_server_opts)
  end

  def start_link(root_action), do: start_link({root_action, []})

  def run(root_action, opts \\ []) do
    with {:ok, pid} <- start_link(root_action, Keyword.merge(opts, respond?: true)),
         do: await(pid)
  end

  def await(pid) do
    receive do
      {__MODULE__, :response, ^pid, response} -> response
    end
  end

  def start_action(action, opts \\ []) do
    Parent.Client.start_child(parent(), action_spec(action),
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
  def init({root_action, opts}) do
    case Parent.start_child(
           task_spec(root_action, respond_to: opts.respond_to, from: self()),
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

  defp action_spec(fun) when is_function(fun, 0), do: task_spec(fun)
  defp action_spec({_module, _fun, _args} = mfa), do: task_spec(mfa)
  defp action_spec({module, arg}), do: action_spec(module.job_action_spec(arg))
  defp action_spec(module) when is_atom(module), do: action_spec({module, []})
  defp action_spec(%{} = spec), do: spec

  defp action_spec(other), do: raise("Unknown action spec: #{inspect(other)}")

  defp task_spec(invocable, opts \\ []) do
    respond_to = Keyword.get(opts, :respond_to, self())
    {Task, fn -> respond(respond_to, invoke(invocable), opts) end}
  end

  defp invoke(fun) when is_function(fun, 0), do: fun.()
  defp invoke({module, function, args}), do: apply(module, function, args)
  defp invoke({module, arg}), do: module.run(arg)

  defp send_exit_response(from, reason, meta) do
    if reason != :normal, do: respond(meta.respond_to, {:exit, reason}, from: from)
  end

  defp parent, do: hd(Process.get(:"$ancestors"))

  defp respond(pid, response, opts) do
    unless is_nil(pid),
      do: send(pid, {__MODULE__, :response, Keyword.get(opts, :from, self()), response})

    :ok
  end
end
