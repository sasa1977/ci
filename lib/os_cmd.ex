defmodule OsCmd do
  use GenServer

  defmodule Error do
    defexception [:message, :exit_status]
  end

  def start_link(command) when is_binary(command), do: start_link({command, []})

  def start_link({command, opts}) do
    with {:ok, args} <- parse_command(command),
         {terminate_cmd, opts} = Keyword.pop(opts, :terminate_cmd, ""),
         {:ok, terminate_cmd_parts} <- parse_command(terminate_cmd) do
      args =
        args(opts) ++ Enum.flat_map(terminate_cmd_parts, &["-terminate-cmd-part", &1]) ++ args

      opts = normalize_opts(opts)

      GenServer.start_link(
        __MODULE__,
        {args, opts},
        Keyword.take(opts, [:name])
      )
    end
  end

  def stop(server, reason \\ :normal, timeout \\ :infinity),
    do: GenServer.stop(server, reason, timeout)

  @impl GenServer
  def init({args, opts}) do
    Process.flag(:trap_exit, true)

    with {:ok, timeout} <- Keyword.fetch(opts, :timeout),
         do: Process.send_after(self(), :timeout, timeout)

    case open_port(args) do
      {:ok, port} ->
        {:ok,
         %{
           port: port,
           handler: Keyword.get(opts, :handler),
           propagate_exit?: Keyword.get(opts, :propagate_exit?, false)
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_info({port, {:exit_status, exit_status}}, %{port: port} = state),
    # Delegating to `handle_continue` because we must invoke a custom handler which can crash, so
    # we need to make sure that the correct state is committed.
    do: {:noreply, %{state | port: nil}, {:continue, {:stop, exit_status}}}

  def handle_info({port, {:data, message}}, %{port: port} = state) do
    invoke_handler(state, message)
    {:noreply, state}
  end

  def handle_info(:timeout, state), do: stop_server(state, :timeout)

  @impl GenServer
  def handle_continue({:stop, exit_status}, state) do
    invoke_handler(state, {:stopped, exit_status})
    exit_reason = if exit_status == 0, do: :normal, else: {:failed, exit_status}
    stop_server(%{state | port: nil}, exit_reason)
  end

  @impl GenServer
  def terminate(_reason, %{port: nil}), do: :ok
  def terminate(_reason, %{port: port}), do: stop_program(port)

  defp args(opts) do
    Enum.flat_map(
      opts,
      fn
        {:cd, dir} -> ["-dir", dir]
        _other -> []
      end
    )
  end

  defp normalize_opts(opts) do
    handler =
      opts
      |> Keyword.get_values(:notify)
      |> Enum.reduce(
        Keyword.get(opts, :handler),
        fn pid, handler ->
          fn message ->
            send(pid, {self(), message})
            handler && handler.(message)
          end
        end
      )

    Keyword.put(opts, :handler, handler)
  end

  defp stop_server(%{propagate_exit?: false} = state, _exit_reason), do: {:stop, :normal, state}
  defp stop_server(state, reason), do: {:stop, reason, state}

  defp invoke_handler(%{handler: nil}, _message), do: :ok

  defp invoke_handler(%{handler: handler}, message) do
    message = with message when is_binary(message) <- message, do: :erlang.binary_to_term(message)
    handler.(message)
  end

  defp open_port(args) do
    with {:ok, port_executable} <- port_executable() do
      port =
        Port.open({:spawn_executable, port_executable}, [
          :exit_status,
          :binary,
          packet: 4,
          args: args
        ])

      receive do
        {^port, {:data, "started"}} ->
          {:ok, port}

        {^port, {:data, "not started " <> error}} ->
          Port.close(port)
          {:error, %Error{message: error}}

        {^port, {:exit_status, _exit_status}} ->
          exit("unexpected port exit")
      end
    end
  end

  defp port_executable do
    Application.app_dir(:ci, "priv")
    |> Path.join("os_cmd*")
    |> Path.wildcard()
    |> case do
      [executable] -> {:ok, executable}
      _ -> {:error, %Error{message: "can't find os_cmd executable"}}
    end
  end

  defp stop_program(port) do
    Port.command(port, "stop")

    receive do
      {^port, {:exit_status, _exit_status}} -> :ok
    end
  end

  defp parse_command(input) do
    case next_arg(input) do
      {:error, _} = error ->
        error

      :eof ->
        {:ok, []}

      {:ok, arg, rest_input} ->
        with {:ok, other_args} <- parse_command(rest_input),
             do: {:ok, [arg | other_args]}
    end
  end

  defp next_arg(input) do
    with {:ok, input} <- skip_whitespaces(input),
         {:ok, chars, rest_input} <- arg_chars(input),
         do: {:ok, to_string(chars), rest_input}
  end

  defp skip_whitespaces(""), do: :eof

  defp skip_whitespaces(<<c, rest_input::binary>>) when c in [?\s, ?\t, ?\n, ?\r],
    do: skip_whitespaces(rest_input)

  defp skip_whitespaces(input), do: {:ok, input}

  defp arg_chars(""), do: :eof

  defp arg_chars(<<c, rest_input::binary>> = input) do
    cond do
      c in [?\s, ?\t, ?\n, ?\r] ->
        {:ok, [], input}

      c in [?", ?'] ->
        with {:ok, chars, rest_input} <- quoted_chars(rest_input, c) do
          case arg_chars(rest_input) do
            {:ok, more_chars, rest_input} -> {:ok, chars ++ more_chars, rest_input}
            :eof -> {:ok, chars, ""}
            error -> error
          end
        end

      true ->
        case arg_chars(rest_input) do
          {:ok, chars, rest_input} -> {:ok, [c | chars], rest_input}
          :eof -> {:ok, [c], ""}
          error -> error
        end
    end
  end

  defp quoted_chars("", quote_char),
    do: {:error, %Error{message: "missing closing #{[quote_char]}"}}

  defp quoted_chars(<<quote_char, rest_input::binary>>, quote_char),
    do: {:ok, [], rest_input}

  defp quoted_chars(<<?\\, quote_char, rest_input::binary>>, quote_char) do
    with {:ok, chars, rest_input} <- quoted_chars(rest_input, quote_char),
         do: {:ok, [quote_char | chars], rest_input}
  end

  defp quoted_chars(<<char, rest_input::binary>>, quote_char) do
    with {:ok, chars, rest_input} <- quoted_chars(rest_input, quote_char),
         do: {:ok, [char | chars], rest_input}
  end
end
