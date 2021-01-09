defmodule Mix.Tasks.Ci.CheckTest do
  # sync because of IO capture
  use ExUnit.Case, async: false
  alias Mix.Tasks.Ci.Check

  test "performs all checks" do
    assert run_checks() == :ok

    assert_receive {:command, "mix compile --warnings-as-errors"}
    assert_receive {:command, "mix test"}
    assert_receive {:command, "mix format --check-formatted"}
  end

  test "reports error" do
    assert_raise(
      Mix.Error,
      ~r/mix test exited with status 1.*mix test output/s,
      fn ->
        run_checks(
          cmd_stub: fn
            "mix test" -> {:ok, 1, "mix test output"}
            _ -> {:ok, 0, ""}
          end
        )
      end
    )
  end

  defp run_checks(opts \\ []) do
    test_pid = self()

    OsCmd.stub(fn command, _opts ->
      send(test_pid, {:command, command})
      Keyword.get(opts, :cmd_stub, fn _ -> {:ok, 0, ""} end).(command)
    end)

    ExUnit.CaptureIO.capture_io(fn -> send(self(), {:result, Check.run(nil)}) end)
    assert_receive {:result, result}
    result
  end
end
