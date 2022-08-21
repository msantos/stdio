defmodule StdioSupervisorTest do
  use ExUnit.Case
  use Stdio

  setup do
    Stdio.__setuid__(false)
    {:ok, supervisor} = Stdio.supervisor(:noshutdown)

    on_exit(fn -> :prx.stop(supervisor.init) end)

    %{supervisor: supervisor}
  end

  describe "stream" do
    test "sh: exec process writing to stdout", config do
      supervisor = config.supervisor

      result =
        Stdio.stream!(
          "echo test",
          Stdio.with_supervisor(__MODULE__, supervisor)
        )
        |> Enum.take(1)

      assert [stdout: "test\n"] = result
    end
  end

  describe "pipe" do
    test "enumerable to process stdin", config do
      supervisor = config.supervisor
      e = "test\n"

      result =
        [e, e, e]
        |> Stdio.pipe!(
          "cat",
          Stdio.with_supervisor(__MODULE__, supervisor)
        )
        |> Enum.to_list()

      # events may be merged into 1 event
      assert [{:stdout, <<"test\n", _::binary>>} | _] = result
    end

    test "pipe buffer full", config do
      supervisor = config.supervisor
      e = String.duplicate("x", 100)

      # Send stdin to a command that does not read standard
      # input. Writes to the process stdin will eventually fail
      # with EAGAIN.
      #
      # byte_size(e) = 100 bytes
      # 98 * 1000 = 100000 bytes
      #
      # See pipe(7):
      #
      # In  Linux  versions before 2.6.11, the capacity of a pipe was the
      # same as the system page size (e.g., 4096 bytes on i386).  Since Linux
      # 2.6.11, the pipe capacity is 16 pages (i.e., 65,536 bytes in a system
      # with a page size of 4096 bytes).  Since Linux 2.6.35, the default pipe
      # capacity  is  16 pages, but the capacity can be queried and set using
      # the fcntl(2) F_GETPIPE_SZ and F_SETPIPE_SZ operations.  See fcntl(2)
      # for more information.
      result =
        Stream.cycle([e])
        |> Stream.take(1_000)
        |> Stdio.pipe!(
          "sleep 700",
          Stdio.with_supervisor(__MODULE__, supervisor)
        )
        |> Enum.to_list()

      assert [{:stderr, "{:error, {:eagain, 0}}"}, {:termsig, :sigkill}] == result || [] == result

      termsig =
        receive do
          {:termsig, _, _} = sig -> sig
        after
          0 ->
            :ok
        end

      assert :ok = termsig
    end

    test "subprocess exits", config do
      supervisor = config.supervisor

      result =
        ["x", "x", "x", "x"]
        |> Stdio.pipe!(
          "exit 3",
          Stdio.with_supervisor(__MODULE__, supervisor)
        )
        |> Enum.to_list()

      assert [exit_status: 3] = result

      # Check the message is flushed from the process mailbox:
      #
      # * subprocess exits
      # * parent writes to subprocess stdin
      # * parent receives sigpipe
      signal =
        receive do
          {:signal, _, _, _} = sig -> sig
        after
          0 ->
            :ok
        end

      assert :ok = signal
    end
  end

  describe "pipeline" do
    test "send process stdout to process stdin", config do
      supervisor = config.supervisor

      result =
        Stdio.stream!(
          "while :; do echo test; sleep 1; done",
          Stdio.with_supervisor(__MODULE__, supervisor)
        )
        |> Stream.transform(<<>>, &Stdio.Stream.stdout_to_stderr/2)
        |> Stdio.pipe!(
          "cat",
          Stdio.with_supervisor(__MODULE__, supervisor)
        )
        |> Enum.take(1)

      assert [stdout: <<"test\n", _::binary>>] = result
    end
  end

  @impl Stdio
  def init(_config) do
    fn init ->
      __fork__(init, 10)
    end
  end

  defp __fork__(init, n), do: __fork__(init, n, [])

  defp __fork__(_init, 0, inits), do: {:ok, Enum.reverse(inits)}

  defp __fork__(init, n, inits) do
    case :prx.fork(init) do
      {:ok, task} ->
        __fork__(task, n - 1, [Stdio.ProcessTree.task(task) | inits])

      {:error, _} = error ->
        for pid <- Enum.reverse(inits), do: :prx.stop(pid)
        error
    end
  end
end
