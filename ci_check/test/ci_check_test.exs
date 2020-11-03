defmodule CiCheckTest do
  use ExUnit.Case

  test "succeeds if all commands succeed" do
    OsCmd.stub(fn _, _ -> {:ok, 0, ""} end)
    assert {_, _} = run_check()
  end

  test "runs all commands" do
    {_output, executed_cmds} = run_check()

    assert executed_cmds == %{
             ci_check: [
               "mix compile --warnings-as-errors",
               "mix format --check-formatted",
               "mix test"
             ],
             ci: [
               "mix deps.get",
               "mix compile --warnings-as-errors",
               "mix format --check-formatted",
               "mix test"
             ]
           }
  end

  defp run_check do
    test_pid = self()

    OsCmd.stub(fn command, opts ->
      send(test_pid, {:command, {Keyword.get(opts, :cd, "."), command}})
      {:ok, 0, ""}
    end)

    output = ExUnit.CaptureIO.capture_io(&CiCheck.run/0)

    executed_cmds =
      Stream.repeatedly(fn ->
        receive do
          {:command, command} -> command
        after
          0 -> nil
        end
      end)
      |> Stream.take_while(&(not is_nil(&1)))
      |> Stream.map(fn
        {".", cmd} -> {:ci_check, cmd}
        {"..", cmd} -> {:ci, cmd}
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    {output, executed_cmds}
  end
end
