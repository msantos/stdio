defmodule StdioContainerTest do
  use ExUnit.Case

  @moduletag :linux
  doctest Stdio.Container

  setup_all do
    Stdio.Container.make_chroot_tree!()

    # /opt: create a test bind mount
    path = Application.get_env(:stdio, :root, Stdio.__basedir__())
    File.mkdir_p!(Path.join([path, "opt"]))

    script = Path.join([path, "opt", "stdiotrue"])
    File.write!(script, "")
    File.chmod!(script, 0o755)
  end

  setup do
    Stdio.setuid()
  end

  test "sh: exec process writing to stdout" do
    result = Stdio.stream!("echo test", Stdio.Container) |> Enum.take(1)
    assert [stdout: "test\n"] = result
  end

  test "sh: set UID/GID" do
    result =
      Stdio.stream!("id -a", Stdio.Container, uid: 65_578)
      |> Enum.take(1)

    assert [stdout: "uid=65578 gid=65578 groups=65578\n"] = result
  end

  test "pipe: send process stdout to process stdin" do
    result =
      Stdio.stream!("while :; do echo test; sleep 1; done")
      |> Stream.transform(<<>>, &Stdio.Stream.stdout_to_stderr/2)
      |> Stdio.pipe!("cat")
      |> Enum.take(1)

    assert [stdout: <<"test\n", _::binary>>] = result
  end

  test "pipe: enumerable to process stdin" do
    e = "test\n"

    result =
      [e, e, e]
      |> Stdio.pipe!("cat", Stdio.Container)
      |> Enum.to_list()

    # events may be merged into 1 event
    assert [{:stdout, <<"test\n", _::binary>>} | _] = result
  end

  test "pipe: pipe buffer full" do
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
      |> Stdio.pipe!("sleep 900", Stdio.Container)
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

  test "pipe: subprocess exits" do
    result =
      ["x", "x", "x", "x"]
      |> Stdio.pipe!("exit 3", Stdio.Container)
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

  test "mount: verify mount flags" do
    [{:stdout, e} | _] = Stdio.stream!("mount", Stdio.Container) |> Enum.to_list()

    # [
    #   ["/dev/vdb", "on", "/", "type", "btrfs",
    #    "(ro,nosuid,relatime,discard,space_cache,user_subvol_rm_allowed,\
    #    subvolid=425,subvol=/lxd/storage-pools/default/containers/test)"]
    # ]
    flags =
      e
      # split mount output into lines
      |> String.split("\n")
      # and each line into words
      |> Enum.map(fn x -> x |> String.split() end)
      # select the root directory mount point
      |> Enum.filter(fn x -> "/" == x |> Enum.at(2) end)
      # flatten to list from list of lists
      |> List.first()
      # mount flags are the last element of the list
      |> List.last()
      # split up the mount flags
      |> String.split([",", "(", ")"], trim: true)
      # select the mount flags being tested
      |> Enum.filter(fn
        "ro" -> true
        "nosuid" -> true
        _ -> false
      end)
      |> Enum.sort()

    assert ["nosuid", "ro"] = flags
  end

  test "mount: /opt from relative path" do
    result =
      Stdio.stream!("PATH=/opt:$PATH stdiotrue", Stdio.Container, fstab: ["opt"])
      |> Enum.to_list()

    assert [{:exit_status, 0}] = result
  end

  test "sh: setuid/shared network" do
    result =
      Stdio.stream!(
        "ping -c 1 127.0.0.1",
        Stdio.Container,
        setuid: true,
        net: :host
      )
      |> Enum.to_list()

    # [stdout: <<"PING 127.0.0.1", _::binary>>, exit_status: 0]
    assert {:stdout, <<"PING 127.0.0.1", _::binary>>} = List.first(result)
    assert {:exit_status, 0} = List.last(result)
  end
end
