defmodule OsCmdTest do
  use ExUnit.Case, async: false

  test "returns error on invalid program" do
    assert {:error, error} = OsCmd.start_link("unknown_program")
    assert error.message =~ "executable file not found"
  end

  test "returns error on invalid directory" do
    Process.flag(:trap_exit, true)
    assert {:error, error} = OsCmd.start_link({"echo 1", cd: "/unknown/directory"})
    assert error.message =~ "no such file or directory"
  end

  test "stops the process after the command finishes" do
    Process.flag(:trap_exit, true)
    {:ok, pid} = OsCmd.start_link("echo 1")
    assert_receive {:EXIT, ^pid, :normal}
  end

  test "sends notifications when configured" do
    {:ok, pid} = OsCmd.start_link({"echo 1", notify: self()})
    assert_receive {^pid, {:output, "1\n"}}
    assert_receive {^pid, {:stopped, 0}}
  end

  test "returns the correct exit code" do
    {:ok, pid} = OsCmd.start_link({~s/bash -c "exit 42"/, notify: self()})
    assert_receive {^pid, {:stopped, 42}}
  end

  test "sets the correct folder" do
    {:ok, pid} = OsCmd.start_link({"pwd", notify: self(), cd: "test"})
    assert_receive {^pid, {:output, output}}
    assert output |> String.trim_trailing() |> Path.relative_to_cwd() == "test"
  end

  test "executes the specified terminate command" do
    Process.flag(:trap_exit, true)
    {:ok, pid1} = OsCmd.start_link("sleep infinity")
    {:ok, pid2} = OsCmd.start_link({"sleep infinity", terminate_cmd: "killall sleep"})

    OsCmd.stop(pid2)

    assert_receive {:EXIT, ^pid1, :normal}
    assert_receive {:EXIT, ^pid2, :normal}
  end

  test "terminates the program on stop" do
    on_exit(fn -> File.rm("test.txt") end)

    {:ok, pid} =
      OsCmd.start_link("""
      bash -c "
        while true; do
          echo 1 >> test.txt
          sleep 0.001
        done
      "
      """)

    Process.sleep(100)
    assert OsCmd.stop(pid) == :ok

    contents = File.read!("test.txt")
    Process.sleep(100)
    assert File.read!("test.txt") == contents
  end

  test "terminates the program when the owner process dies" do
    on_exit(fn -> File.rm("test.txt") end)

    test_pid = self()

    {:ok, owner_pid} =
      Agent.start_link(fn ->
        {:ok, cmd_pid} =
          OsCmd.start_link("""
          bash -c "
            while true; do
              echo 1 >> test.txt
              sleep 0.001
            done
          "
          """)

        send(test_pid, cmd_pid)
      end)

    assert_receive cmd_pid
    Process.monitor(cmd_pid)

    Process.sleep(100)
    Agent.stop(owner_pid)

    assert_receive {:DOWN, _mref, :process, ^cmd_pid, _}

    contents = File.read!("test.txt")
    Process.sleep(100)
    assert File.read!("test.txt") == contents
  end

  test "terminates the program if it doesn't complete in the given time" do
    Process.flag(:trap_exit, true)
    {:ok, pid} = OsCmd.start_link({"sleep infinity", timeout: 1})
    assert_receive {:EXIT, ^pid, :normal}
  end

  @tag capture_log: true
  test "propagates exit reason" do
    Process.flag(:trap_exit, true)

    {:ok, pid} = OsCmd.start_link({~s/bash -c "exit 0"/, propagate_exit?: true})
    assert_receive {:EXIT, ^pid, :normal}

    {:ok, pid} = OsCmd.start_link({~s/bash -c "exit 1"/, propagate_exit?: true})
    assert_receive {:EXIT, ^pid, {:failed, 1}}

    {:ok, pid} = OsCmd.start_link({~s/sleep infinity/, propagate_exit?: true, timeout: 1})
    assert_receive {:EXIT, ^pid, :timeout}
  end
end
