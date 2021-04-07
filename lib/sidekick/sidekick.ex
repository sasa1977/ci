defmodule Sidekick do
  @spec start(atom, [Parent.child_spec()]) :: :ok | {:error, :already_started | :boot_error}
  def start(node_name, children) do
    ensure_distributed!()

    node = :"#{node_name}@#{hostname()}"

    if Node.ping(node) == :pong,
      do: {:error, :already_started},
      else: start_node(node, children)
  end

  defp ensure_distributed! do
    System.cmd("epmd", ["-daemon"])

    node_name = :crypto.strong_rand_bytes(16) |> Base.encode32(padding: false, case: :lower)

    case :net_kernel.start([:"#{node_name}@127.0.0.1"]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  @doc false
  def sidekick_init([encoded_input]) do
    {caller, children} =
      encoded_input
      |> to_string()
      |> Base.decode32!(padding: false)
      |> :erlang.binary_to_term()

    {:ok, _} = Application.ensure_all_started(:elixir)
    {:ok, _} = Application.ensure_all_started(:parent)

    parent_node = node(caller)
    true = Node.connect(parent_node)

    {:ok, _} = Sidekick.Supervisor.start(parent_node, children)

    send(caller, {__MODULE__, :initialized})
  end

  defp hostname do
    [_name, hostname] = String.split("#{node()}", "@", parts: 2)
    hostname
  end

  defp start_node(sidekick_node, children) do
    command = start_node_command(sidekick_node, children)
    port = Port.open({:spawn, command}, [:stream, :exit_status])

    # Note that we're not using a timeout, because sidekick is programmed to connect to this node
    # or self-terminate if that fails. Therefore, the situation where sidekick is running but not
    # connected isn't possible.
    receive do
      # {:nodeup, ^sidekick_node} -> :ok
      {__MODULE__, :initialized} -> :ok
      {^port, {:exit_status, _status}} -> {:error, :boot_error}
    end
  end

  defp start_node_command(sidekick_node, children) do
    {:ok, command} = :init.get_argument(:progname)

    name_arg =
      case :net_kernel.longnames() do
        true -> "-name #{sidekick_node}"
        false -> "-sname #{sidekick_node}"
        _ -> raise "not in distributed mode"
      end

    base_args = "-noinput #{name_arg}"

    priv_dir = :code.priv_dir(:ci)
    boot_file_args = "-boot #{priv_dir}/node"

    cookie = Node.get_cookie()
    cookie_arg = "-setcookie #{cookie}"

    paths_args = :code.get_path() |> Enum.map(&"-pa #{&1}") |> Enum.join(" ")

    encoded_arg = {self(), children} |> :erlang.term_to_binary() |> Base.encode32(padding: false)
    command_args = "-run Elixir.Sidekick sidekick_init #{encoded_arg}"

    args = "#{base_args} #{boot_file_args} #{cookie_arg} #{paths_args} #{command_args}"

    "#{command} #{args}"
  end
end
