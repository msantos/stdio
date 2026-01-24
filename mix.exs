defmodule Stdio.MixProject do
  use Mix.Project

  @version "0.4.5"

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

  defp package do
    [
      licenses: ["ISC"],
      links: %{
        github: "https://github.com/msantos/stdio",
        codeberg: "https://codeberg.org/msantos/stdio"
      }
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
            :seccomp,
            Stdio.Jail,
            Stdio.ProcessTree,
            Stdio.Syscall,
            Stdio.Syscall.FreeBSD,
            Stdio.Syscall.OpenBSD
          ]

        {:unix, :freebsd} ->
          [
            :seccomp,
            Stdio.Container,
            Stdio.ProcessTree,
            Stdio.Rootless,
            Stdio.Syscall,
            Stdio.Syscall.Linux,
            Stdio.Syscall.OpenBSD
          ]

        {:unix, :openbsd} ->
          [
            :seccomp,
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
            :seccomp,
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
          <script defer src="https://cdn.jsdelivr.net/npm/mermaid/dist/mermaid.min.js"></script>
          <script>
          let initialized = false;

          window.addEventListener("exdoc:loaded", () => {
          if (!initialized) {
          mermaid.initialize({
          startOnLoad: false,
          theme: document.body.className.includes("dark") ? "dark" : "default"
          });
          initialized = true;
          }

          let id = 0;
          for (const codeEl of document.querySelectorAll("pre code.mermaid")) {
          const preEl = codeEl.parentElement;
          const graphDefinition = codeEl.textContent;
          const graphEl = document.createElement("div");
          const graphId = "mermaid-graph-" + id++;
          mermaid.render(graphId, graphDefinition).then(({svg, bindFunctions}) => {
          graphEl.innerHTML = svg;
          bindFunctions?.(graphEl);
          preEl.insertAdjacentElement("afterend", graphEl);
          preEl.remove();
          });
          }
          });
          </script>
          """

        _ ->
          ""
      end
    ]
  end

  defp deps do
    [
      {:alcove, "~> 1.0.1"},
      {:prx, "~> 1.0.1"},
      {:credo, "~> 1.6", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.1", only: [:dev], runtime: false},
      {:ex_doc, "~> 0.28", only: :dev, runtime: false},
      {:gradient, github: "esl/gradient", only: [:dev], runtime: false}
    ]
  end
end
