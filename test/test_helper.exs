ExUnit.start()
unless System.get_env("CI") == "true", do: ExUnit.configure(exclude: [ci: true])
