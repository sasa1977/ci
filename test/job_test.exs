defmodule JobTest do
  use ExUnit.Case, async: false

  describe "job" do
    test "stops when the given function finishes" do
      Process.flag(:trap_exit, true)
      assert {:ok, job} = Job.start_link(fn -> :ok end)
      assert_receive {:EXIT, ^job, :normal}
    end

    test "doesn't send the response message back by default" do
      {:ok, _job} = Job.start_link(fn -> :ok end)
      refute_receive _
    end

    test "can be awaited on" do
      {:ok, job} = Job.start_link({fn -> :foo end, respond?: true})
      assert Job.await(job) == :foo
    end

    test "can be synchronously executed with run" do
      assert Job.run(fn -> :foo end) == :foo
    end

    test "accepts MFA" do
      assert Job.run({Kernel, :abs, [-1]}) == 1
    end

    @tag capture_log: true
    test "stops with the same exit reason as the root action process" do
      Process.flag(:trap_exit, true)
      assert {:ok, job} = Job.start_link(fn -> exit(:foo) end)
      assert_receive {:EXIT, ^job, :foo}
    end

    @tag capture_log: true
    test "always stops with reason `normal` if response is being sent back" do
      Process.flag(:trap_exit, true)
      assert {:ok, job} = Job.start_link({fn -> exit(:foo) end, respond?: true})
      refute_receive {:EXIT, ^job, :foo}
    end

    @tag capture_log: true
    test "returns the job exit reason" do
      assert Job.run(fn -> exit(:foo) end) == {:exit, :foo}
    end

    @tag capture_log: true
    test "can be timed out" do
      Process.flag(:trap_exit, true)
      assert {:ok, job} = Job.start_link({fn -> Process.sleep(:infinity) end, timeout: 1})
      assert_receive {:EXIT, ^job, :timeout}
    end
  end

  describe "action" do
    test "can be started and awaited on" do
      res =
        Job.run(fn ->
          {:ok, pid1} = Job.start_action(fn -> 1 end)
          {:ok, pid2} = Job.start_action(fn -> 2 end)
          Job.await(pid1) + Job.await(pid2)
        end)

      assert res == 3
    end

    test "can be synchronously executed with run_action" do
      res =
        Job.run(fn ->
          Job.run_action(fn -> 1 end) + Job.run_action(fn -> 2 end)
        end)

      assert res == 3
    end

    test "can be timed out" do
      res =
        Job.run(fn ->
          res = Job.run_action(fn -> Process.sleep(:infinity) end, timeout: 1)
          {:res, res}
        end)

      assert res == {:res, {:exit, :timeout}}
    end
  end

  describe "sequence" do
    test "runs all actions sequentially, returning all the results" do
      {:ok, job} =
        Job.start_link({
          {:sequence,
           [
             new_action(1, fn -> {:ok, 1} end),
             new_action(2, fn -> {:ok, 2} end)
           ]},
          respond?: true
        })

      assert_receive {:action_started, 1, action1}
      refute_receive {:action_started, 2, _}

      send(action1, :continue)

      assert_receive {:action_started, 2, action2}
      send(action2, :continue)

      assert Job.await(job) == {:ok, [1, 2]}
    end

    test "stops on first error and returns it" do
      {:ok, job} =
        Job.start_link({
          {:sequence,
           [
             new_action(1, fn -> {:ok, 1} end),
             new_action(2, fn -> {:error, 2} end),
             new_action(3, fn -> {:ok, 3} end)
           ]},
          respond?: true
        })

      assert_receive {:action_started, 1, action1}
      send(action1, :continue)

      assert_receive {:action_started, 2, action2}
      send(action2, :continue)

      refute_receive {:action_started, 3, _action3}

      assert Job.await(job) == {:error, 2}
    end

    @tag capture_log: true
    test "converts crash into an error" do
      assert {:error, {exception, _stacktrace}} = Job.run({:sequence, [fn -> raise "foo" end]})
      assert exception == %RuntimeError{message: "foo"}
    end
  end

  describe "parallel" do
    test "runs all actions in parallel, returning all the results" do
      {:ok, job} =
        Job.start_link({
          {:parallel,
           [
             new_action(1, fn -> {:ok, 1} end),
             new_action(2, fn -> {:ok, 2} end)
           ]},
          respond?: true
        })

      assert_receive {:action_started, 1, action1}
      assert_receive {:action_started, 2, action2}

      send(action1, :continue)
      send(action2, :continue)

      assert Job.await(job) == {:ok, [1, 2]}
    end

    test "returns all errors if some actions fail" do
      res =
        Job.run(
          {:parallel,
           [
             fn -> {:error, 1} end,
             fn -> {:ok, 2} end,
             fn -> {:error, 3} end
           ]}
        )

      assert res == {:error, [1, 3]}
    end

    @tag capture_log: true
    test "converts crash into an error" do
      assert {:error, [{exception, _stacktrace}]} = Job.run({:parallel, [fn -> raise "foo" end]})
      assert exception == %RuntimeError{message: "foo"}
    end
  end

  describe "pipeline" do
    test "can consist of nested sequences and parallels" do
      res =
        Job.run(
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
           ]}
        )

      assert res == {:ok, [1, [2, [3, 4, 5], 6], 7]}
    end

    test "can be executed as an action" do
      assert Job.run(fn -> Job.run_action({:sequence, [fn -> {:ok, 1} end]}) end) == {:ok, [1]}
    end
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
