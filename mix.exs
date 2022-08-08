defmodule Stdio.MixProject do
  use Mix.Project

  @version "0.3.0"

  def project do
    [
      app: :stdio,
      version: @version,
      elixir: "~> 1.13",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      description: """
      Stream standard I/O from system processes.

      Reliably reap, restrict and isolate system tasks: Stdio is a
      control plane for processes.
      """,
      package: package(),
      source_url: "https://github.com/msantos/stdio",
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
      {:alcove, "~> 0.40.4"},
      {:prx, "~> 0.16.2"},
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
      source_ref: "v#{@version}",
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
