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
end
