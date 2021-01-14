defmodule Job.Pipeline do
  @moduledoc """
  High-level interface for running `Job`-powered pipeline of actions.

  A pipeline is a collection of actions which can be executed in sequence or parallel, and which
  all have to succeed for the job to succeed.

  ## Example

      Job.run(
        Pipeline.sequence([
          action_1,
          action_2,
          Pipeline.parallel([action_3, action_4]),
          action_5
        ])
      )

  Such pipeline can be visually represented as:

  ```text
                       -> action_3
  action_1 -> action_2              -> action_5
                       -> action_4
  ```

  An action inside a pipeline can be any `t:Job.action/0` that responds with `{:ok, result} | {:error, reason}`. Other
  responses are not supported. An action crash will be converted into an `{:error, exit_reason}` response.

  A pipeline succeeds if all of its action succeed. In such case, the response of the pipeline is the list of responses
  of each action. For the example above, the successful response will be:

      {:ok, [
        action_1_response,
        action_2_response,
        [action_3_response, action_4_response],
        action_5_response,
      ]}

  An error response depends on the type of pipeline. A sequence pipeline stops on first error, responding with
  `{:error, reason}`. A parallel pipeline waits for all the actions to finish. If any of them responded with an error,
  the aggregated response will be `{:error, [error1, error2, ...]}`.

  Note that in a nested pipeline, where the top-level element is a sequence, an error response can be
  `{:error, action_error | [action_error]}`. In addition, the list of errors might be nested. You can consider using
  functions such as `List.wrap/1` and `List.flatten/1` to convert the error(s) into a flat list.
  """

  @doc """
  Returns a specification for running a sequential pipeline as a `Job` action.

  The corresponding action will return `{:ok, [action_result]} | {:error, action_error}`
  See `Job.start_action/2` for details.
  """
  @spec sequence([Job.action()], [Job.action_opt()]) :: Job.action()
  def sequence(actions, opts \\ []), do: &{{Task, fn -> &1.(run_sequence(actions)) end}, opts}

  @doc """
  Returns a specification for running a parallel pipeline as a `Job` action.

  The corresponding action will return `{:ok, [action_result]} | {:error, [action_error]}`
  See `Job.start_action/2` for details.
  """
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
