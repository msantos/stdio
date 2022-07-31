defmodule Stdio.MixProject do
  use Mix.Project

  def project do
    [
      app: :stdio,
      version: "0.1.0",
      elixir: "~> 1.13",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      description: "Isolate, reap, restrict and stream standard I/O from system processes",
      package: package(),
      aliases: aliases(),
      test_coverage: test_coverage(),
      dialyzer: [
        list_unused_filters: true,
        flags: [
          :unmatched_returns,
          :error_handling,
          :race_conditions,
          :underspecs
        ]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:alcove, "~> 0.40.3"},
      {:prx, "~> 0.16.1"},
      {:credo, "~> 1.6", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.1", only: [:dev], runtime: false},
      {:ex_doc, "~> 0.28", only: :dev, runtime: false},
      {:gradient, github: "esl/gradient", only: [:dev], runtime: false}
    ]
  end

  defp package do
    [
      maintainers: ["Michael Santos"],
      licenses: ["ISC"],
      links: %{github: "https://github.com/msantos/stdio"}
    ]
  end

  defp aliases do
    [
      check: ["gradient", "credo", "dialyzer"]
    ]
  end

  defp test_coverage do
    modules =
      case :os.type() do
        {:unix, :linux} ->
          [
            Stdio.Jail,
            Stdio.ProcessTree,
            Stdio.Syscall,
            Stdio.Syscall.FreeBSD,
            Stdio.Syscall.OpenBSD
          ]

        {:unix, :freebsd} ->
          [
            Stdio.Container,
            Stdio.ProcessTree,
            Stdio.Rootless,
            Stdio.Syscall,
            Stdio.Syscall.Linux,
            Stdio.Syscall.OpenBSD
          ]

        {:unix, :openbsd} ->
          [
            Stdio.Container,
            Stdio.Jail,
            Stdio.ProcessTree,
            Stdio.Rootless,
            Stdio.Syscall,
            Stdio.Syscall.FreeBSD,
            Stdio.Syscall.Linux
          ]

        _ ->
          [
            Stdio.Container,
            Stdio.Jail,
            Stdio.ProcessTree,
            Stdio.Rootless,
            Stdio.Syscall.FreeBSD,
            Stdio.Syscall.Linux,
            Stdio.Syscall.OpenBSD
          ]
      end

    [{:ignore_modules, modules}]
  end

  defp docs do
    [
      extras: [
        "README.md": [title: "Overview"]
      ],
      main: "readme",
      before_closing_body_tag: fn
        :html ->
          """
          <script src="https://cdn.jsdelivr.net/npm/mermaid/dist/mermaid.min.js"></script>
          <script>mermaid.initialize({startOnLoad: true})</script>
          """

        _ ->
          ""
      end
    ]
  end
end
