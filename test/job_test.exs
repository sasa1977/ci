defmodule JobTest do
  # sync because of log capture
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
      {:ok, job} = Job.start_link(fn -> :foo end, respond?: true)
      assert Job.await(job) == :foo
    end

    test "can be synchronously executed with run" do
      assert Job.run(fn -> :foo end) == :foo
    end

    test "accepts MFA" do
      assert Job.run({Kernel, :abs, [-1]}) == 1
    end

    test "accepts childspec factory function" do
      assert Job.run(&{Task, fn -> &1.(:foo) end}) == :foo
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
      assert {:ok, job} = Job.start_link(fn -> exit(:foo) end, respond?: true)
      refute_receive {:EXIT, ^job, :foo}
    end

    @tag capture_log: true
    test "returns the job exit reason" do
      assert Job.run(fn -> exit(:foo) end) == {:exit, :foo}
    end

    @tag capture_log: true
    test "can be timed out" do
      Process.flag(:trap_exit, true)
      assert {:ok, job} = Job.start_link(fn -> Process.sleep(:infinity) end, timeout: 1)
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

    @tag capture_log: true
    test "can be timed out" do
      res =
        Job.run(fn ->
          res = Job.run_action(fn -> Process.sleep(:infinity) end, timeout: 1)
          {:res, res}
        end)

      assert res == {:res, {:exit, :timeout}}
    end

    @tag capture_log: true
    test "crash is converted into an exit error" do
      res =
        Job.run(fn ->
          res = Job.run_action(fn -> exit("foo") end)
          {:res, res}
        end)

      assert res == {:res, {:exit, "foo"}}
    end

    @tag capture_log: true
    test "crash takes down child actions" do
      test_pid = self()

      res =
        Job.run(fn ->
          {:ok, non_crashed_action} =
            Job.start_action(fn ->
              Process.sleep(100)
              :ok
            end)

          Job.run_action(fn ->
            Job.start_action(fn ->
              Process.flag(:trap_exit, true)
              send(test_pid, {:child_pid, self()})

              receive do
                {:EXIT, _parent, :shutdown} -> :ok
              end
            end)

            Job.start_action(
              fn ->
                Process.flag(:trap_exit, true)
                send(test_pid, {:child_pid, self()})
                Process.sleep(:infinity)
              end,
              shutdown: :brutal_kill
            )

            raise "foo"
          end)

          Job.await(non_crashed_action)
        end)

      assert res == :ok

      for _ <- 1..2 do
        assert_receive {:child_pid, child_pid}
        mref = Process.monitor(child_pid)
        assert_receive {:DOWN, ^mref, :process, ^child_pid, _}
      end
    end
  end

  describe "child_spec" do
    test "accepts action" do
      caller = self()
      start_supervised!({Job, fn -> send(caller, :foo) end}, restart: :temporary)
      assert_receive :foo
    end

    test "accepts action and opts" do
      job = start_supervised!({Job, {fn -> :foo end, respond_to: self()}})
      assert Job.await(job) == :foo
    end
  end
end
