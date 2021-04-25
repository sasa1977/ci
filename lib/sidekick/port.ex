defmodule Sidekick.Port do
  @moduledoc false

  use GenServer
  require Logger

  def start_link(node_name, children) do
    node = :"#{node_name}@#{hostname()}"

    if Node.ping(node) == :pong,
      do: {:error, :already_started},
      else: GenServer.start_link(__MODULE__, {node, children})
  end

  def open(pid, command) do
    GenServer.cast(pid, {:open, command})
  end

  @impl GenServer
  def init({node, children}) do
    command = start_node_command(node, children)
    port = Port.open({:spawn, command}, [:stream, :exit_status])

    receive do
      {Sidekick, :initialized} -> {:ok, port}
      {^port, {:exit_status, _status}} -> {:stop, :boot_error}
    end
  end

  @impl GenServer
  def handle_info({port, {:data, data}}, port) do
    Logger.debug("Port got message #{inspect(data)}")
    {:noreply, port}
  end

  def handle_info({port, {:exit_status, reason}}, port) do
    Logger.debug("Port closed with reason #{reason}")
    {:stop, :normal, port}
  end

  defp hostname do
    [_name, hostname] = String.split("#{node()}", "@", parts: 2)
    hostname
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

    "#{command} #{base_args} #{boot_file_args} #{cookie_arg} #{paths_args} #{command_args}"
  end
end
