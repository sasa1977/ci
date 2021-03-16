defmodule Sidekick do
  @spec start(atom, [{atom, any}]) :: {:error, any} | :ok
  def start(node_name \\ :docker, children) do
    ensure_distributed!()

    node = :"#{node_name}@#{hostname()}"

    if Node.ping(node) == :pong do
      {:error, :already_started}
    else
      with :ok <- start_node(node), do: start_remote_supervisor(node, children)
    end
  end

  defp ensure_distributed! do
    node_name = :crypto.strong_rand_bytes(16) |> Base.encode32(padding: false, case: :lower)

    case :net_kernel.start([:"#{node_name}@127.0.0.1"]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  @doc false
  def sidekick_init([parent_node]) do
    if Node.connect(parent_node) in [false, :ignored],
      do: :init.stop()
  end

  defp hostname do
    [_name, hostname] = String.split("#{node()}", "@", parts: 2)
    hostname
  end

  defp start_remote_supervisor(sidekick_node, children) do
    case :rpc.block_call(sidekick_node, Sidekick.Supervisor, :start_link, [node(), children]) do
      {:ok, _pid} -> :ok
      other -> {:error, other}
    end
  end

  defp start_node(sidekick_node) do
    :net_kernel.monitor_nodes(true)
    command = start_node_command(sidekick_node)
    port = Port.open({:spawn, command}, [:stream, :exit_status])

    # Note that we're not using a timeout, because sidekick is programmed to connect to this node
    # or self-terminate if that fails. Therefore, the situation where sidekick is running but not
    # connected isn't possible.
    receive do
      {:nodeup, ^sidekick_node} -> :ok
      {^port, {:exit_status, status}} -> {:error, {:node_stopped, status}}
    end
  end

  defp start_node_command(sidekick_node) do
    {:ok, command} = :init.get_argument(:progname)

    base_args = "-noinput -name #{sidekick_node}"

    priv_dir = :code.priv_dir(:ci)
    boot_file_args = "-boot #{priv_dir}/node"

    cookie = Node.get_cookie()
    cookie_arg = "-setcookie #{cookie}"

    paths_args = :code.get_path() |> Enum.map(&"-pa #{&1}") |> Enum.join(" ")

    command_args = "-s Elixir.Sidekick sidekick_init #{node()}"

    args = "#{base_args} #{boot_file_args} #{cookie_arg} #{paths_args} #{command_args}"

    "#{command} #{args}"
  end
end
