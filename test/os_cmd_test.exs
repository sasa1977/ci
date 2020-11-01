defmodule OsCmdTest do
  use ExUnit.Case, async: false

  with {:error, _} <- OsCmd.port_executable(), do: @moduletag(skip: true)

  if match?({:win32, _}, :os.type()) do
    test "sends notifications when configured" do
      pid = start_cmd!(~s[cmd /C "echo 1"], notify: self())
      assert_receive {^pid, {:output, "1\r\n"}}
      assert_receive {^pid, {:stopped, 0}}
    end
  else
    describe "GenServer" do
      test "returns error on invalid program" do
        assert {:error, error} = start_cmd("unknown_program")
        assert error.message =~ "executable file not found"
      end

      test "returns error on invalid directory" do
        Process.flag(:trap_exit, true)
        assert {:error, error} = start_cmd("dir", cd: "/unknown/directory")
        assert error.message =~ "no such file or directory"
      end

      test "sends notifications when configured" do
        pid = start_cmd!("echo 1", notify: self())
        assert_receive {^pid, {:output, "1\n"}}
        assert_receive {^pid, {:stopped, 0}}
      end

      test "inherits environment" do
        System.put_env("FOO", "bar")
        pid = start_cmd!(~s/bash -c "echo $FOO"/, notify: self())
        assert_receive {^pid, {:output, "bar\n"}}
      end

      test "overrides environment" do
        System.put_env("FOO", "bar")
        pid = start_cmd!(~s/bash -c "echo $FOO"/, notify: self(), env: [{"FOO", "baz"}])
        assert_receive {^pid, {:output, "baz\n"}}
      end

      test "sets environment" do
        pid = start_cmd!(~s/bash -c "echo $BAR"/, notify: self(), env: [{"BAR", "baz"}])
        assert_receive {^pid, {:output, "baz\n"}}
      end

      test "unsets environment" do
        System.put_env("FOO", "bar")
        pid = start_cmd!(~s/bash -c "echo $FOO"/, notify: self(), env: [{"FOO", nil}])
        assert_receive {^pid, {:output, "\n"}}
      end

      test "supports list as input" do
        pid = start_cmd!(~w/echo 1/, notify: self())
        assert_receive {^pid, {:output, "1\n"}}
      end

      test "supports quoted args" do
        pid = start_cmd!(~s/bash -c "echo 1"/)
        assert_receive {^pid, {:output, "1\n"}}

        pid = start_cmd!(~s/bash -c "echo '\\"'"/)
        assert_receive {^pid, {:output, ~s/"\n/}}

        pid = start_cmd!(~s/bash -c 'echo 1'/)
        assert_receive {^pid, {:output, "1\n"}}

        pid = start_cmd!(~s/bash -c 'echo "\\'"'/)
        assert_receive {^pid, {:output, ~s/'\n/}}
      end

      test "returns the correct exit code" do
        pid = start_cmd!(~s/bash -c "exit 42"/, notify: self())
        assert_receive {^pid, {:stopped, 42}}
      end

      test "sets the correct folder" do
        pid = start_cmd!("pwd", notify: self(), cd: "test")
        assert_receive {^pid, {:output, output}}
        assert output |> String.trim_trailing() |> Path.relative_to_cwd() == "test"
      end

      test "executes the specified terminate command" do
        Process.flag(:trap_exit, true)
        pid1 = start_cmd!("sleep 999999999")

        pid2 =
          start_cmd!("sleep 999999999",
            terminate_cmd: ~s/bash -c "echo terminating; killall sleep"/
          )

        OsCmd.stop(pid2)

        assert_receive {:EXIT, ^pid1, :normal}
        assert_receive {:EXIT, ^pid2, :normal}
        assert_receive {^pid2, {:output, "terminating\n"}}
      end

      test "terminates the program on stop" do
        on_exit(fn -> File.rm("test.txt") end)

        pid =
          start_cmd!("""
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
            cmd_pid =
              start_cmd!("""
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
        pid = start_cmd!("sleep 999999999", timeout: 1)
        assert_receive {:EXIT, ^pid, :normal}
      end

      @tag capture_log: true
      test "propagates exit reason" do
        Process.flag(:trap_exit, true)

        pid = start_cmd!(~s/bash -c "exit 0"/, propagate_exit?: true)
        assert_receive {:EXIT, ^pid, :normal}

        pid = start_cmd!(~s/bash -c "exit 1"/, propagate_exit?: true)
        assert_receive {:EXIT, ^pid, {:failed, 1}}

        pid = start_cmd!(~s/sleep 999999999/, propagate_exit?: true, timeout: 1)
        assert_receive {:EXIT, ^pid, :timeout}
      end

      test "notifies all processes and invokes the custom handler" do
        Process.flag(:trap_exit, true)

        output =
          ExUnit.CaptureIO.capture_io(fn ->
            pid = start_cmd!("echo 1", notify: self(), notify: self(), handler: &IO.inspect/1)
            assert_receive {^pid, {:output, "1\n"}}
            assert_receive {^pid, {:output, "1\n"}}

            assert_receive {^pid, {:stopped, 0}}
            assert_receive {^pid, {:stopped, 0}}

            # prevents a crash in the cmd process due to race condition with captureio
            assert_receive {:EXIT, ^pid, _}
          end)

        assert output =~ ~s/{:output, "1\\n"/
      end
    end

    describe "events stream" do
      test "returns the stream of messages" do
        pid = start_cmd!("echo 1")
        assert Enum.to_list(OsCmd.events(pid)) == [output: "1\n", stopped: 0]
      end

      test "leaves non-processed messages in the message queue" do
        pid = start_cmd!("echo 1")
        assert Enum.take(OsCmd.events(pid), 1) == [output: "1\n"]
        assert_receive {^pid, {:stopped, 0}}
      end

      test "handles process crash" do
        Process.flag(:trap_exit, true)
        pid = start_cmd!(~s/bash -c "echo 1; sleep 999999999"/)

        events =
          pid
          |> OsCmd.events()
          |> Enum.map(fn event ->
            with {:output, _} <- event, do: Process.exit(pid, :kill)
          end)

        assert events == [true, {:terminated, :killed}]
      end
    end

    describe "run" do
      test "returns output if the program succeeds" do
        assert OsCmd.run(~s/bash -c "echo 1; echo 2 >&2; echo 3"/) == {:ok, "1\n2\n3\n"}
      end

      test "returns error if the program fails" do
        assert OsCmd.run(~s/bash -c "echo 1; exit 2"/) == {:error, 2, "1\n"}
      end

      test "returns error if the owner terminates" do
        Process.flag(:trap_exit, true)

        task =
          Task.async(fn ->
            Process.flag(:trap_exit, true)
            OsCmd.run("sleep 999999999")
          end)

        Process.sleep(100)
        {:links, links} = Process.info(task.pid, :links)
        [cmd_pid] = links -- [self()]
        Process.exit(cmd_pid, :kill)

        assert Task.await(task) == {:error, :killed, ""}
      end
    end
  end

  defp start_cmd(command, opts \\ []) do
    opts = Keyword.merge([notify: self()], opts)
    OsCmd.start_link({command, opts})
  end

  defp start_cmd!(command, opts \\ []) do
    {:ok, pid} = start_cmd(command, opts)
    pid
  end
end
