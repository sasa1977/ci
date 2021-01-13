defmodule Job.Pipeline do
  @spec sequence([Job.action()], [Job.action_opt()]) :: Job.action()
  def sequence(actions, opts \\ []), do: &{{Task, fn -> &1.(run_sequence(actions)) end}, opts}

  @spec parallel([Job.action()], [Job.action_opt()]) :: Job.action()
  def parallel(actions, opts \\ []), do: &{{Task, fn -> &1.(run_parallel(actions)) end}, opts}

  defp run_sequence(actions) do
    result =
      Enum.reduce_while(
        actions,
        [],
        fn action, previous_results ->
          result =
            with {:ok, pid} <- start_action(action),
                 do: await_pipeline_action(pid)

          case result do
            {:ok, result} -> {:cont, [result | previous_results]}
            {:error, _} = error -> {:halt, error}
          end
        end
      )

    with results when is_list(results) <- result, do: {:ok, Enum.reverse(results)}
  end

  defp run_parallel(actions) do
    actions
    |> Enum.map(&start_action/1)
    |> Enum.map(&with {:ok, pid} <- &1, do: await_pipeline_action(pid))
    |> Enum.split_with(&match?({:ok, _}, &1))
    |> case do
      {successess, []} -> {:ok, Enum.map(successess, fn {:ok, result} -> result end)}
      {_, errors} -> {:error, Enum.map(errors, fn {_, result} -> result end)}
    end
  end

  defp start_action(action), do: Job.start_action(action, timeout: :infinity)

  defp await_pipeline_action(pid) do
    case Job.await(pid) do
      {:ok, _} = success -> success
      {:error, _} = error -> error
      {:exit, reason} -> {:error, reason}
      _other -> raise "Pipeline action must return `{:ok, result} | {:error, reason}`"
    end
  end
end
