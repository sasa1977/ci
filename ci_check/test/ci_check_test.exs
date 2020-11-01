defmodule CiCheckTest do
  use ExUnit.Case

  test "succeeds if all commands succeed" do
    OsCmd.stub(fn _, _ -> {:ok, 0, ""} end)
    assert CiCheck.run() == :ok
  end

  test "runs all commands" do
    Enum.each(
      [
        "mix deps.get",
        "mix compile --warnings-as-errors",
        "mix format --check-formatted",
        "mix test"
      ],
      &OsCmd.expect/1
    )

    CiCheck.run()
    Mox.verify!()
  end

  test "prints output of commands" do
    output =
      ExUnit.CaptureIO.capture_io(fn ->
        OsCmd.stub(fn command, _ -> {:ok, 0, "output of #{command}\n"} end)
        CiCheck.run()
      end)

    assert output ==
             """
             output of mix deps.get
             output of mix compile --warnings-as-errors
             output of mix format --check-formatted
             output of mix test
             """
  end

  test "reports errors of unrelated commands in a single pass" do
    OsCmd.stub(fn
      "mix format --check-formatted", _ -> {:ok, 1, ""}
      "mix test", _ -> {:ok, 2, ""}
      _, _ -> {:ok, 0, ""}
    end)

    error = assert_raise(RuntimeError, fn -> CiCheck.run() == :ok end)
    assert error.message =~ "mix format --check-formatted exited with status 1"
    assert error.message =~ "mix test exited with status 2"
  end
end
