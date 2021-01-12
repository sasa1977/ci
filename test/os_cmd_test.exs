defmodule OsCmdTest do
  # sync because of log capture
  use ExUnit.Case, async: false

  with {:error, _} <- OsCmd.Port.executable(), do: @moduletag(skip: true)

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

      test "can use pty" do
        pid = start_cmd!("echo 1", notify: self(), pty: true)
        assert_receive {^pid, {:output, "1\r\n"}}
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

      test "accepts atom as env name" do
        pid = start_cmd!(~s/bash -c "echo $BAR"/, notify: self(), env: [bar: "baz"])
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
        Process.flag(:trap_exit, true)
        on_exit(fn -> File.rm("test.txt") end)

        test_pid = self()

        {:ok, owner_pid} =
          Task.start_link(fn ->
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
            Process.sleep(:infinity)
          end)

        assert_receive cmd_pid
        Process.monitor(cmd_pid)

        Process.sleep(100)
        Process.exit(owner_pid, :shutdown)

        assert_receive {:DOWN, _mref, :process, ^cmd_pid, _}

        contents = File.read!("test.txt")
        Process.sleep(100)
        assert File.read!("test.txt") == contents
      end

      @tag capture_log: true
      test "terminates the program if it doesn't complete in the given time" do
        Process.flag(:trap_exit, true)
        pid = start_cmd!("sleep 999999999", timeout: 1)
        assert_receive {:EXIT, ^pid, :timeout}
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

      test "invokes the custom zero arity handler" do
        test_pid = self()
        start_cmd!("echo 1", handler: &send(test_pid, &1))

        assert_receive :starting
        assert_receive {:output, "1\n"}
        assert_receive {:stopped, 0}
      end

      test "supports accumulating handler" do
        test_pid = self()

        handler = {
          [],
          fn
            {:stopped, _}, messages -> send(test_pid, messages)
            message, messages -> [message | messages]
          end
        }

        OsCmd.run("echo 1", handler: handler)

        assert_receive [{:output, "1\n"}, :starting]
      end

      @tag capture_log: true
      test "crashes on handler crash" do
        Process.flag(:trap_exit, true)

        assert {:error, {%RuntimeError{message: "foo"}, _stacktrace}, "1\n"} =
                 OsCmd.run(~s/bash -c "echo 1; sleep 999999999"/,
                   handler: &with({:output, _} <- &1, do: raise("foo"))
                 )

        assert_receive {:EXIT, _pid, {%RuntimeError{message: "foo"}, _stacktrace}}
      end
    end

    describe "events stream" do
      test "returns the stream of messages" do
        pid = start_cmd!("echo 1")
        assert Enum.to_list(OsCmd.events(pid)) == [:starting, output: "1\n", stopped: 0]
      end

      test "leaves non-processed messages in the message queue" do
        pid = start_cmd!("echo 1")
        assert Enum.take(OsCmd.events(pid), 2) == [:starting, output: "1\n"]
        assert_receive {^pid, {:stopped, 0}}
      end

      test "handles process crash" do
        Process.flag(:trap_exit, true)
        pid = start_cmd!(~s/bash -c "echo 1; sleep 999999999"/)

        last_event =
          pid
          |> OsCmd.events()
          |> Enum.map(fn event ->
            with {:output, _} <- event, do: Process.exit(pid, :shutdown)
            event
          end)
          |> Enum.at(-1)

        assert last_event == {:stopped, :shutdown}
      end
    end

    describe "run" do
      test "returns output if the program succeeds" do
        assert OsCmd.run(~s/bash -c "echo 1; echo 2 >&2; echo 3"/) == {:ok, "1\n2\n3\n"}
      end

      test "returns error if the program fails" do
        assert OsCmd.run(~s/bash -c "echo 1; exit 2"/) == {:error, 2, "1\n"}
      end
    end
  end

  describe "expect" do
    test "returns output and exit status" do
      OsCmd.expect(fn _command, _opts -> {:ok, 1, "foo"} end)
      assert OsCmd.run("echo 1") == {:error, 1, "foo"}
    end

    test "uses fake from the closest ancestor" do
      OsCmd.expect(fn _command, _opts -> {:ok, 1, "foo"} end)

      result =
        Task.async(fn ->
          OsCmd.expect(fn _command, _opts -> {:ok, 1, "bar"} end)

          Task.async(fn -> OsCmd.run("echo 1") end)
          |> Task.await()
        end)
        |> Task.await()

      assert result == {:error, 1, "bar"}
    end

    test "uses allowances" do
      test_pid = self()

      {:ok, pid} =
        Task.start_link(fn ->
          assert_receive :continue
          send(test_pid, OsCmd.run("echo 1"))
        end)

      Task.start_link(fn ->
        OsCmd.allow(pid)
        OsCmd.expect(fn _command, _opts -> {:ok, 0, "foo"} end)
        send(pid, :continue)
        Process.sleep(:infinity)
      end)

      assert_receive {:ok, "foo"}
    end

    test "returns start error" do
      Process.flag(:trap_exit, true)
      OsCmd.expect(fn _command, _opts -> {:error, "foo"} end)
      assert OsCmd.run("echo 1") == {:error, "foo"}
    end

    test "matches expectations" do
      OsCmd.expect(fn "echo 1", _ -> {:ok, 0, "foo"} end)
      OsCmd.expect(fn "echo 2", _ -> {:ok, 0, "bar"} end)

      assert OsCmd.run("echo 1") == {:ok, "foo"}
      assert OsCmd.run("echo 2") == {:ok, "bar"}
    end

    test "fails if expectation is not met" do
      OsCmd.expect(fn _, _ -> {:ok, 0, ""} end)
      assert_raise(Mox.VerificationError, fn -> Mox.verify!() end)
    end
  end

  describe "stub" do
    test "doesn't have to be called" do
      OsCmd.stub(fn _command, _opts -> {:ok, 1, "foo"} end)
      Mox.verify!()
    end

    test "can be called more than once" do
      OsCmd.stub(fn _command, _opts -> {:ok, 0, "foo"} end)
      assert OsCmd.run("echo 1") == {:ok, "foo"}
      assert OsCmd.run("echo 1") == {:ok, "foo"}
    end
  end

  describe "job action" do
    test "can be started" do
      OsCmd.stub(fn _command, _opts -> {:ok, 0, "foo"} end)
      assert Job.run(fn -> Job.run_action({OsCmd, "foo"}) end) == {:ok, "foo"}
    end

    test "interprets non-zero exit status as error" do
      OsCmd.stub(fn _command, _opts -> {:ok, 1, "some error"} end)
      assert {:error, %OsCmd.Error{} = error} = Job.run(fn -> Job.run_action({OsCmd, "foo"}) end)
      assert error.message =~ "foo exited with status 1"
      assert error.message =~ "some error"
    end
  end

  defp start_cmd(command, opts \\ []) do
    opts =
      [notify: self()]
      |> Keyword.merge(opts)
      |> Enum.map(fn opt ->
        with {:notify, pid} <- opt,
             do: {:handler, &send(pid, {self(), &1})}
      end)

    OsCmd.start_link({command, opts})
  end

  defp start_cmd!(command, opts \\ []) do
    {:ok, pid} = start_cmd(command, opts)
    pid
  end
end
