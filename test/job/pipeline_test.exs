defmodule Job.PipelineTest do
  # sync because of log capture
  use ExUnit.Case, async: false

  alias Job.Pipeline

  describe "sequence" do
    test "runs all actions sequentially, returning all the results" do
      {:ok, job} =
        Job.start_link(
          {Pipeline,
           {:sequence,
            [
              new_action(1, fn -> {:ok, 1} end),
              new_action(2, fn -> {:ok, 2} end)
            ]}},
          respond?: true
        )

      assert_receive {:action_started, 1, action1}
      refute_receive {:action_started, 2, _}

      send(action1, :continue)

      assert_receive {:action_started, 2, action2}
      send(action2, :continue)

      assert Job.await(job) == {:ok, [1, 2]}
    end

    test "stops on first error and returns it" do
      {:ok, job} =
        Job.start_link(
          {Pipeline,
           {:sequence,
            [
              new_action(1, fn -> {:ok, 1} end),
              new_action(2, fn -> {:error, 2} end),
              new_action(3, fn -> {:ok, 3} end)
            ]}},
          respond?: true
        )

      assert_receive {:action_started, 1, action1}
      send(action1, :continue)

      assert_receive {:action_started, 2, action2}
      send(action2, :continue)

      refute_receive {:action_started, 3, _action3}

      assert Job.await(job) == {:error, 2}
    end

    @tag capture_log: true
    test "converts crash into an error" do
      assert {:error, {exception, _stacktrace}} =
               Job.run({Pipeline, {:sequence, [fn -> raise "foo" end]}})

      assert exception == %RuntimeError{message: "foo"}
    end
  end

  describe "parallel" do
    test "runs all actions in parallel, returning all the results" do
      {:ok, job} =
        Job.start_link(
          {Pipeline,
           {:parallel,
            [
              new_action(1, fn -> {:ok, 1} end),
              new_action(2, fn -> {:ok, 2} end)
            ]}},
          respond?: true
        )

      assert_receive {:action_started, 1, action1}
      assert_receive {:action_started, 2, action2}

      send(action1, :continue)
      send(action2, :continue)

      assert Job.await(job) == {:ok, [1, 2]}
    end

    test "returns all errors if some actions fail" do
      res =
        Job.run(
          {Pipeline,
           {:parallel,
            [
              fn -> {:error, 1} end,
              fn -> {:ok, 2} end,
              fn -> {:error, 3} end
            ]}}
        )

      assert res == {:error, [1, 3]}
    end

    @tag capture_log: true
    test "converts crash into an error" do
      assert {:error, [{exception, _stacktrace}]} =
               Job.run({Pipeline, {:parallel, [fn -> raise "foo" end]}})

      assert exception == %RuntimeError{message: "foo"}
    end
  end

  test "can consist of nested sequences and parallels" do
    res =
      Job.run(
        {Pipeline,
         {:sequence,
          [
            fn -> {:ok, 1} end,
            {:parallel,
             [
               fn -> {:ok, 2} end,
               {:sequence, Enum.map(3..5, &fn -> {:ok, &1} end)},
               fn -> {:ok, 6} end
             ]},
            fn -> {:ok, 7} end
          ]}}
      )

    assert res == {:ok, [1, [2, [3, 4, 5], 6], 7]}
  end

  test "can be executed as an action" do
    assert Job.run(fn -> Job.run_action({Pipeline, {:sequence, [fn -> {:ok, 1} end]}}) end) ==
             {:ok, [1]}
  end

  defp new_action(id, fun) do
    test_pid = self()

    fn ->
      send(test_pid, {:action_started, id, self()})

      receive do
        :continue -> fun.()
      end
    end
  end
end
