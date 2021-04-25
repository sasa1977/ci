defmodule Sidekick do
  @spec start(atom, [Parent.child_spec()]) :: :ok | {:error, :already_started | :boot_error}
  def start(node_name, children) do
    ensure_distributed!()
    Sidekick.Port.start_link(node_name, children)
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

    {:ok, _} = Sidekick.Supervisor.start(caller, children)

    send(caller, {__MODULE__, :initialized})
  end
end
