# CI

[![hex.pm](https://img.shields.io/hexpm/v/ci.svg?style=flat-square)](https://hex.pm/packages/ci)
[![hexdocs.pm](https://img.shields.io/badge/docs-latest-green.svg?style=flat-square)](https://hexdocs.pm/ci/)

CI/CD toolkit as an Elixir library.

## Status

Early alpha. Not tested in any serious production. Expect bugs and breaking changes.

## Basic example

```elixir
Job.run(
  Job.Pipeline.sequence([
    mix("compile --warnings-as-errors"),
    Job.Pipeline.parallel([
      mix("dialyzer"),
      mix("test"),
      mix("format --check-formatted"),
      mix("docs", env: [mix_env: "dev"])
    ])
  ]),
  timeout: :timer.minutes(10)
)
|> report_errors()

defp mix(arg, opts \\ []),
  do: cmd("mix #{arg}", Config.Reader.merge([env: [mix_env: "test"]], opts))

defp cmd(cmd, opts) do
  handler = &IO.write(message(&1, cmd))
  cmd_opts = [handler: handler] ++ Keyword.merge([pty: true], opts)
  OsCmd.action(cmd, cmd_opts)
end

defp message(:starting, cmd), do: "starting #{cmd}\n"
defp message({:output, output}, _cmd), do: output
defp message({:stopped, status}, cmd), do: "#{cmd} stopped with reason #{inspect(status)}"
```

This is the highest level API, which should fit simpler scenarios. For more involved needs, you can replace `Job.Pipeline` with imperative actions powered by `Job`. The example above can be also written as:

```elixir
Job.run(fn ->
  with {:ok, _output} <- Job.run_action(mix("compile --warnings-as-errors")) do
    [
      mix("dialyzer"),
      mix("test"),
      mix("format --check-formatted"),
      mix("docs", env: [mix_env: "dev"])
    ]
    |> Enum.map(&Job.start_action/1)
    |> Enum.map(&Job.await/1)
    |> interpret_results()
  end
end)
```


## Quick start

1. Make sure the prerequisites are installed:

    - Erlang >= 23
    - Elixir >= 1.11
    - go >= 1.15

2. Add CI as a dependency inside your `mix.exs`:

    ```elixir
    # mix.exs

    defp deps do
      [
        {:ci, "~> 0.1.0"},
        # ...
      ]
    end
    ```
3. Invoke `mix ci.init`
4. Invoke `mix my_app.ci`, replacing `my_app` with the name of your OTP app.

The generated CI mix task will first compile the project, and then run `mix test` and `mix format --check-formatted` in parallel. Note that this task may fail if your project requires additional pre-test tasks, such as Ecto repo setup.

You can optionally write a test that verifies your CI flow. See [here](https://github.com/sasa1977/ci/blob/develop/test/ci/mix/check_test.exs) for a simple example.

To run these checks on some CI platform (Travis, Circle, GitHub Actions, ...), you need to make sure prerequisites are installed, and then invoke `mix deps.get`, followed by `mix my_app.ci`. You can see how this project is configured to test itself on GitHub Actions [here](https://github.com/sasa1977/ci/blob/develop/.github/workflows/ci.yaml).

Alternatively, you can consider creating a separate mix project, which only contains the CI mix task. The benefit of this approach is that you can then move all the steps of the tested project inside the mix task. This can be useful if you e.g. need to perform some preparations before fetching deps (e.g. setup ssh credentials, etc).

## Explanation

CI is a collection of small standalone abstractions that can be useful beyond the CI domain:

  - `OsCmd` - Managed execution of OS commands
  - `Job` - Managed execution of potentially failing actions
  - `Job.Pipeline` - a high-level interface for running sequential and parallel pipelines inside a job

Except for the `ci.init` mix task, no special code exists in the `Ci` namespace. The generated client CI code merely combines the abstractions listed above to implement the desired CI flow in Elixir. Using a first-class language instead of an ad-hoc proprietary yaml-based DSL leads to the following benefits:

1. Easy to learn

    If the project is developed in Elixir, everyone on the team is already mostly equipped with the necessary knowledge. Obviously you need to study the docs of the provided abstractions, so you can use them properly, but at least this doesn't require learning a completely different syntax, and the knowledge you gather may serve you beyond the CI domain.

2. Flexible

    Write complex loops and branching logic. Declare variables and organize your code in functions for improved readability and/or reusability. Reap all the benefits of BEAM (support for concurrency and fault-tolerance), and its ecosystem.

    Note that despite being imperative first, CI makes it possible to use a full-declarative proprietary DSL. Converting e.g. a yaml or a json into a series of `Job.Pipeline` actions should be straightforward, and is left as an exercise for the reader :-)

    Being organized as toolkit, rather than a framework, this library leaves a lot of rooms for variations, without requiring a large amount of knobs. You can use only those abstractions that suit your purposes, combining them in whichever way you like. Since most of the code is organized in a porcelain/plumbing way, you can fall back one layer deeper in case you need to make different choices.

3. Local-first

    Easily run the entire flow locally. Test and troubleshoot the problems without pushing commits to trigger an external build.

4. Testable

    Write tests which exercise some critical parts of your CI/CD flow (e.g. a mail is sent on error, or system is deployed after all the checks have passed).

5. Rich tooling

    Use all the tools from the BEAM ecosystem, such as IDE support, debuggers, profilers, ...

## Roadmap

- [ ] Improve Windows support (help needed)
- [ ] Docker support (managing docker images, managed execution of docker containers)
- [ ] VCS wrappers (git, ...)
- [ ] SCM platform clients (e.g. reacting to GitHub events)

## License

[MIT](LICENSE)
