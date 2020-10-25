defmodule OsCmd.ProcessTest do
  use ExUnit.Case, async: false
  alias OsCmd.Process

  test "fails synchronously on startup error" do
    assert {:error, %OsCmd.Error{} = error} = Process.start(["unknown_command"])
    assert error.message =~ "executable file not found"
  end

  test "handles messages sent from the port" do
    {:ok, process} = Process.start(["echo", "hi"])

    assert_receive msg
    assert Process.handle_message(process, msg) == {:output, "hi\n"}

    assert_receive msg
    assert Process.handle_message(process, msg) == {:stopped, 0}
  end

  test "correctly propagates the exit code" do
    {:ok, process} = Process.start(["bash", "-c", "exit 42"])

    assert_receive msg
    assert Process.handle_message(process, msg) == {:stopped, 42}
  end

  test "stops the program" do
    {:ok, process} = Process.start(["sleep", "infinity"])
    assert Process.stop(process) == :ok
    assert :os.cmd('ps aux | grep sleep | grep -v grep') == []
  end
end
