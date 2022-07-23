defmodule StdioTest do
  use ExUnit.Case
  doctest Stdio.Process

  @moduletag :process

  setup do
    Stdio.__setuid__(false)
  end

  describe "stream" do
    test "sh: exec process writing to stdout" do
      result = Stdio.stream!("echo test") |> Enum.take(1)
      assert [stdout: "test\n"] = result
    end

    test "task: fork returns error" do
      result =
        try do
          Stdio.stream!("echo test", {Stdio.Process, task: fn _ -> {:error, :eagain} end})
          |> Enum.to_list()
        catch
          kind, payload ->
            %{kind: kind, payload: payload}
        end

      assert :error = result.kind
      assert :eagain = result.payload.reason
    end

    test "op: operation returns error" do
      result =
        try do
          Stdio.stream!(
            "echo test",
            {Stdio.Process, ops: fn _ -> [{:chdir, ["/nonexistent"]}] end}
          )
          |> Enum.to_list()
        catch
          kind, payload ->
            %{kind: kind, payload: payload}
        end

      assert :error = result.kind
      assert :enoent = result.payload.reason
    end

    test "op: operation returns invalid term" do
      result =
        try do
          Stdio.stream!("echo test", {Stdio.Process, ops: fn _ -> [{:getpid, []}] end})
          |> Enum.to_list()
        catch
          kind, payload ->
            %{kind: kind, payload: payload}
        end

      assert :error = result.kind
      assert :badop = result.payload.reason
    end

    test "op: bad operation" do
      result =
        try do
          Stdio.stream!("echo test", {Stdio.Process, ops: fn _ -> [{:fake_syscall, []}] end})
          |> Enum.to_list()
        catch
          kind, payload ->
            %{kind: kind, payload: payload}
        end

      assert :error = result.kind
      assert :badop = result.payload.reason
    end

    test "exec: set arg0" do
      result =
        Stdio.stream!({"/bin/sh", ["stdio", "-c", "echo $0"]})
        |> Enum.to_list()

      assert [stdout: "stdio\n", exit_status: 0] = result
    end

    test "exec: bad argv" do
      result =
        try do
          Stdio.stream!([])
          |> Enum.to_list()
        catch
          kind, payload ->
            %{kind: kind, payload: payload}
        end

      assert :error = result.kind
      assert :enoent = result.payload.reason
    end

    test "exec: executable not found" do
      result =
        try do
          Stdio.stream!(["executable-does-not-exist"])
          |> Enum.to_list()
        catch
          kind, payload ->
            %{kind: kind, payload: payload}
        end

      assert :error = result.kind
      assert :enoent = result.payload.reason
    end
  end

  describe "pipe" do
    test "enumerable to process stdin" do
      e = "test\n"

      result =
        [e, e, e]
        |> Stdio.pipe!("cat")
        |> Enum.to_list()

      # events may be merged into 1 event
      assert [{:stdout, <<"test\n", _::binary>>} | _] = result
    end

    test "pipe buffer full" do
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
        |> Stdio.pipe!("sleep 900")
        |> Enum.to_list()

      assert [{:stderr, "{:error, {:eagain, 0}}"}, {:termsig, :sigkill}] = result

      termsig =
        receive do
          {:termsig, _, _} = sig -> sig
        after
          0 ->
            :ok
        end

      assert :ok = termsig
    end

    test "subprocess exits" do
      result =
        ["x", "x", "x", "x"]
        |> Stdio.pipe!("exit 3")
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

    test "task: fork returns error" do
      result =
        try do
          ["a", "b", "c"]
          |> Stdio.pipe!("echo test", {Stdio.Process, task: fn _ -> {:error, :eagain} end})
          |> Enum.to_list()
        catch
          kind, payload ->
            %{kind: kind, payload: payload}
        end

      assert :error = result.kind
      assert :eagain = result.payload.reason
    end

    test "op: operation returns error" do
      result =
        try do
          ["a", "b", "c"]
          |> Stdio.pipe!(
            "echo test",
            {Stdio.Process, ops: fn _ -> [{:chdir, ["/nonexistent"]}] end}
          )
          |> Enum.to_list()
        catch
          kind, payload ->
            %{kind: kind, payload: payload}
        end

      assert :error = result.kind
      assert :enoent = result.payload.reason
    end

    test "op: operation returns invalid term" do
      result =
        try do
          ["a", "b", "c"]
          |> Stdio.pipe!("echo test", {Stdio.Process, ops: fn _ -> [{:getpid, []}] end})
          |> Enum.to_list()
        catch
          kind, payload ->
            %{kind: kind, payload: payload}
        end

      assert :error = result.kind
      assert :badop = result.payload.reason
    end

    test "op: bad operation" do
      result =
        try do
          ["a", "b", "c"]
          |> Stdio.pipe!("echo test", {Stdio.Process, ops: fn _ -> [{:fake_syscall, []}] end})
          |> Enum.to_list()
        catch
          kind, payload ->
            %{kind: kind, payload: payload}
        end

      assert :error = result.kind
      assert :badop = result.payload.reason
    end

    test "exec: bad argv" do
      result =
        try do
          ["a", "b", "c"]
          |> Stdio.pipe!([])
          |> Enum.to_list()
        catch
          kind, payload ->
            %{kind: kind, payload: payload}
        end

      assert :error = result.kind
      assert :enoent = result.payload.reason
    end

    test "exec: executable not found" do
      result =
        try do
          ["a", "b", "c"]
          |> Stdio.pipe!(["executable-does-not-exist"])
          |> Enum.to_list()
        catch
          kind, payload ->
            %{kind: kind, payload: payload}
        end

      assert :error = result.kind
      assert :enoent = result.payload.reason
    end
  end

  describe "pipeline" do
    test "send process stdout to process stdin" do
      result =
        Stdio.stream!("while :; do echo test; sleep 1; done")
        |> Stream.transform(<<>>, &Stdio.Stream.stdout_to_stderr/2)
        |> Stdio.pipe!("cat")
        |> Enum.take(1)

      assert [stdout: <<"test\n", _::binary>>] = result
    end

    test "sh: use existing supervisor" do
      {:ok, supervisor} = Stdio.supervisor()

      result1 =
        Stdio.stream!(
          "echo $PPID",
          Stdio.with_supervisor(Stdio.Process, supervisor)
        )
        |> Enum.to_list()

      result2 =
        Stdio.stream!(
          "echo $PPID",
          Stdio.with_supervisor(Stdio.Process, supervisor)
        )
        |> Enum.to_list()

      assert ^result1 = result2

      # share task in resource, new task in pipe
      result3 =
        Stdio.stream!("echo test", Stdio.with_supervisor(Stdio.Process, supervisor))
        |> Stream.transform(<<>>, &Stdio.Stream.stdout_to_stderr/2)
        |> Stdio.pipe!("sed -u 's/t/_/g'", Stdio.Process)
        |> Enum.to_list()

      # FreeBSD: sed may output in 2 writes:
      # [stdout: "_es_\n", exit_status: 0]
      # [{:stdout, "_es_"}, {:stdout, "\n"}, {:exit_status, 0}]
      assert {:stdout, <<"_es_", _::binary>>} = List.first(result3)
      assert {:exit_status, 0} = List.last(result3)

      # share task in resource and pipe
      result4 =
        Stdio.stream!("echo test", Stdio.with_supervisor(Stdio.Process, supervisor))
        |> Stream.transform(<<>>, &Stdio.Stream.stdout_to_stderr/2)
        |> Stdio.pipe!("sed -u 's/t/_/g'", Stdio.with_supervisor(Stdio.Process, supervisor))
        |> Enum.to_list()

      # [stdout: "_es_\n", exit_status: 0]
      # [{:stdout, "_es_"}, {:stdout, "\n"}, {:exit_status, 0}]
      assert {:stdout, <<"_es_", _::binary>>} = List.first(result4)
      assert {:exit_status, 0} = List.last(result4)

      :prx.stop(supervisor.init)
    end
  end
end

defmodule StdioReapTest do
  use ExUnit.Case

  @moduletag :reap

  setup do
    :prx.sudo("")
  end

  test "reap: terminate background processes on exit" do
    procfs = Application.get_env(:stdio, :procfs, Stdio.Syscall.os().procfs())

    # fail if the process is not a subreaper
    {:ok, supervisor} = Stdio.supervisor()
    {:ok, sh} = :prx.fork(supervisor.init)
    :ok = :prx.execvp(sh, ["sh", "-c", "sleep 123 &"])

    # wait for the shell process to exit
    receive do
      {:termsig, ^sh, _} ->
        :ok

      {:exit_status, ^sh, _} ->
        :ok
    end

    # race: PID may be of sh or sleep
    assert [_pid] = Stdio.Procfs.children(:prx.getpid(supervisor.init), procfs)
    :ok = Stdio.reap(supervisor)

    assert [] = Stdio.Procfs.children(:prx.getpid(supervisor.init), procfs)
    :prx.stop(supervisor.init)

    result =
      Stdio.stream!("sleep 300 & sleep 300 & sleep 300 & sleep 300 & echo $$")
      |> Enum.to_list()

    [{:stdout, stdout}, {:exit_status, 0}] = result
    pid = String.to_integer(String.trim(stdout))

    assert [] = Stdio.Procfs.children(pid)
  end

  test "reap: atexit function" do
    atexit = fn init, _sh, _state ->
      Stdio.reap(%Stdio{init: init}, :prx.getpid(init), :SIGKILL)
    end

    {:ok, supervisor} = Stdio.supervisor(atexit)

    result =
      Stdio.stream!("sleep 121 &", Stdio.with_supervisor(Stdio.Process, supervisor))
      |> Enum.to_list()

    assert [exit_status: 0] = result

    assert [] = Stdio.Procfs.children(:prx.getpid(supervisor.init))

    :prx.stop(supervisor.init)
  end
end

defmodule StdioDocTest do
  use ExUnit.Case

  # The Stdio doctests contain some Linux specific tests. As a workaround,
  # seperate the doctests so they can be skipped on other platforms.
  @moduletag :linux
  doctest Stdio

  setup_all do
    Stdio.Container.make_chroot_tree!()
  end

  setup do
    Stdio.setuid()
  end
end
