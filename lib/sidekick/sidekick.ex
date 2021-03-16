defmodule Sidekick do
  @spec start(atom, [{atom, any}]) :: {:error, any} | {:ok, atom, pid}
  def start(node_name \\ :docker, children) do
    parent_node = Node.self()
    node = node_host_name(node_name)

    case Node.ping(node) do
      :pang -> wait_for_sidekick(node, parent_node, children)
      :pong -> {:error, "Sidekick node #{node} is already alive"}
    end
  end

  defp call(node, module, function, args) do
    :rpc.block_call(node, module, function, args)
  end

  @doc false
  def start_sidekick([parent_node]) do
    if Node.connect(parent_node) in [false, :ignored],
      do: :init.stop()
  end

  defp node_host_name(name) do
    hostname = Node.self() |> Atom.to_string() |> String.split("@") |> List.last()
    :"#{name}@#{hostname}"
  end

  defp wait_for_sidekick(sidekick_node, parent_node, children) do
    :net_kernel.monitor_nodes(true)

    with :ok <- start_node(sidekick_node, parent_node) do
      case call(sidekick_node, Sidekick.Supervisor, :start_link, [parent_node, children]) do
        {:ok, pid} ->
          {:ok, sidekick_node, pid}

        {:error, error} ->
          Node.spawn(sidekick_node, :init, :stop, [])
          {:error, error}
      end
    end
  end

  defp start_node(sidekick_node, parent_node) do
    :net_kernel.monitor_nodes(true)
    command = start_node_command(sidekick_node, parent_node)
    Port.open({:spawn, command}, [:stream])

    receive do
      {:nodeup, ^sidekick_node} -> :ok
    after
      5000 ->
        # Shutdown node if we never received a response
        Node.spawn(sidekick_node, :init, :stop, [])
        {:error, :timeout}
    end
  end

  defp start_node_command(sidekick_node, parent_node) do
    {:ok, command} = :init.get_argument(:progname)
    paths = Enum.join(:code.get_path(), " , ")

    base_args = "-noinput -name #{sidekick_node}"

    priv_dir = :code.priv_dir(:ci)
    boot_file_args = "-boot #{priv_dir}/node"

    cookie = Node.get_cookie()
    cookie_arg = "-setcookie #{cookie}"

    paths_arg = "-pa #{paths}"

    command_args = "-s Elixir.Sidekick start_sidekick #{parent_node}"

    args = "#{base_args} #{boot_file_args} #{cookie_arg} #{paths_arg} #{command_args}"

    "#{command} #{args}"
  end
end
