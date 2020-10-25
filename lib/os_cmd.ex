defmodule OsCmd do
  defmodule Error do
    defexception [:message, :exit_code]
  end
end
