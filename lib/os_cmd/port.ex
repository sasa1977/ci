defmodule OsCmd.Port do
  @moduledoc false

  import NimbleParsec
  @behaviour OsCmd.Program

  def start(command, opts) do
    with {:ok, cmd_args} <- normalize_command(command),
         {terminate_cmd, opts} = Keyword.pop(opts, :terminate_cmd, ""),
         {:ok, terminate_cmd_parts} <- normalize_command(terminate_cmd),
         args =
           args(opts)
           |> Enum.concat(Enum.flat_map(terminate_cmd_parts, &["-terminate-cmd-part", &1]))
           |> Enum.concat(cmd_args),
         {:ok, executable} <- executable() do
      port =
        Port.open(
          {:spawn_executable, executable},
          [
            :exit_status,
            :binary,
            packet: 4,
            args: args
          ] ++ Keyword.take(opts, ~w/env/a)
        )

      receive do
        {^port, {:data, "started"}} ->
          {:ok, port}

        {^port, {:data, "not started " <> error}} ->
          Port.close(port)
          {:error, %OsCmd.Error{message: error}}

        {^port, {:exit_status, _exit_status}} ->
          {:error, %OsCmd.Error{message: "unexpected port exit"}}
      end
    end
  end

  def executable do
    Application.app_dir(:ci, "priv")
    |> Path.join("os_cmd*")
    |> Path.wildcard()
    |> case do
      [executable] -> {:ok, executable}
      _ -> {:error, %OsCmd.Error{message: "can't find os_cmd executable"}}
    end
  end

  defp args(opts) do
    Enum.flat_map(
      opts,
      fn
        {:cd, dir} -> ["-dir", dir]
        _other -> []
      end
    )
  end

  defp normalize_command(list) when is_list(list), do: {:ok, list}

  defp normalize_command(input) when is_binary(input) do
    case parse_arguments(input) do
      {:ok, args, "", _context, _line, _column} -> {:ok, args}
      {:error, reason, rest, _context, _line, _column} -> raise "#{reason}: #{rest}"
    end
  end

  whitespaces = [?\s, ?\n, ?\r, ?\t]

  unquoted = utf8_string(Enum.map(whitespaces, &{:not, &1}), min: 1)

  quoted = fn quote_char ->
    ignore(utf8_char([quote_char]))
    |> repeat(
      choice([
        ignore(utf8_char([?\\])) |> utf8_char([quote_char, ?\\]),
        utf8_char([{:not, quote_char}])
      ])
    )
    |> ignore(utf8_char([quote_char]))
    |> reduce({Kernel, :to_string, []})
  end

  arguments =
    repeat(
      ignore(repeat(utf8_char(whitespaces)))
      |> choice([
        quoted.(?"),
        quoted.(?'),
        lookahead_not(utf8_char([?", ?'])) |> concat(unquoted)
      ])
      |> ignore(repeat(utf8_char(whitespaces)))
    )
    |> eos()

  defparsecp :parse_arguments, arguments
end
