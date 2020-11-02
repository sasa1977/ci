defmodule JobTest do
  use ExUnit.Case, async: false

  test "stops when the task finishes" do
    Process.flag(:trap_exit, true)
    assert {:ok, job} = Job.start_link(fn -> :ok end)
    assert_receive {:EXIT, ^job, :normal}
  end

  @tag capture_log: true
  test "stops with the same exit reason as task" do
    Process.flag(:trap_exit, true)
    assert {:ok, job} = Job.start_link(fn -> exit(:foo) end)
    assert_receive {:EXIT, ^job, :foo}
  end

  @tag capture_log: true
  test "times out the job" do
    Process.flag(:trap_exit, true)
    assert {:ok, job} = Job.start_link({fn -> Process.sleep(:infinity) end, timeout: 1})
    assert_receive {:EXIT, ^job, :timeout}
  end

  describe "run/2" do
    test "returns the job result" do
      assert Job.run(fn -> 1 + 2 end) == {:ok, 3}
    end

    @tag capture_log: true
    test "returns the job exit reason" do
      Process.flag(:trap_exit, true)
      assert Job.run(fn -> exit(:foo) end) == {:error, :foo}
    end
  end

  describe "task" do
    test "can be started and awaited on" do
      res =
        Job.run(fn ->
          task1 = Job.start_task(fn -> 1 end)
          task2 = Job.start_task(fn -> 2 end)

          with {:ok, res1} <- Job.await_task(task1),
               {:ok, res2} <- Job.await_task(task2),
               do: res1 + res2
        end)

      assert res == {:ok, 3}
    end

    test "can be timed out" do
      res =
        Job.run(fn ->
          Job.start_task(fn -> Process.sleep(:infinity) end, 1)
          |> Job.await_task()
        end)

      assert res == {:ok, {:error, :killed}}
    end
  end

  describe "os_cmd" do
    test "can be started and awaited on" do
      OsCmd.stub(fn _, _ -> {:ok, 0, ""} end)

      Job.run(fn ->
        assert Job.await_os_cmd(Job.start_os_cmd("echo 1")) == :ok
      end)
    end

    test "can be executed synchronously" do
      OsCmd.stub(fn _, _ -> {:ok, 0, ""} end)
      Job.run(fn -> assert Job.run_os_cmd("echo 1") == :ok end)
    end

    test "returns an error" do
      OsCmd.stub(fn _, _ -> {:ok, 1, ""} end)
      Job.run(fn -> assert Job.run_os_cmd("echo 1") == {:error, 1} end)
    end
  end
end
