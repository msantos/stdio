defmodule Stdio.Container do
  use Stdio

  @moduledoc ~S"""
  Namespaced Linux processes

  Run a process in a Linux
  [namespace](https://man7.org/linux/man-pages/man7/namespaces.7.html).

  ## Privileges

  To use this behaviour, the system process supervisor must have root
  privileges. These privileges are dropped before running the command.

  Root privileges can be enabled by setting the setuid bit on the `prx`
  executable or by running it under a program like `sudo(8)`.

  ## Operations

  > #### Mount Namespace Root (chroot) Directory {: .info}
  > The chroot directory structure must be created before using this
  > behaviour.
  >
  > See `make_chroot_tree!/0` and `make_chroot_tree!/1`.

  See `t:Stdio.config/0` for configuration options.

  * creates a process in a new UTS, IPC, PID, mount and by default,
    net namespace

  * creates a new session

  * sets the process priority [:priority=0]

  * bind mounts as read-only /bin, /sbin, /usr, /lib and the list
    specified in `fstab` into the container mount namespace

  * mounts /tmp and /home as tmpfs filesystems

  * changes the mount namespace root directory to the chroot

  * sets resource limits defined in the `rlimit` option [:rlimit=disable
    coredumps]

  * sends the process a SIGKILL if the parent process exits

  * sets additional groups as specified in the `group` option
    [:groups=remove additional groups]

  * drops privileges to the value of `uid` and `gid` or a high UID system
    user [:uid/:gid=65536-131071]

  * disables the ability of the process to escalate privileges [:setuid=false]

  > #### Warning {: .warning}
  > The generated UID/GID may overlap with existing users.

  ## Examples

      iex> Stdio.stream!("pstree", Stdio.Container) |> Enum.to_list()
      [stdout: "sh---pstree\n", exit_status: 0]

  """

  @doc """
  Create the container root directory structure.

  Creates the directory structure set in the application environment. The
  default is:

      # the default is set to the application priv directory: priv/root
      config :stdio,
        path: "/tmp/root"

  """
  def make_chroot_tree!() do
    make_chroot_tree!(
      Application.get_env(
        :stdio,
        :path,
        Path.join(Stdio.__basedir__(), "root")
      )
    )
  end

  @doc """
  See `make_chroot_tree!/0`
  """
  def make_chroot_tree!(path) do
    ["bin", "sbin", "usr", "lib", "lib64", "opt", "tmp", "home", "proc"]
    |> Enum.each(fn dir -> File.mkdir_p!(Path.join(path, dir)) end)
  end

  @impl true
  def task(_config) do
    Stdio.supervisor(:noreap)
  end

  @impl true
  def init(config) do
    flags = [
      :clone_newipc,
      :clone_newns,
      :clone_newpid,
      :clone_newuts
    ]

    flags =
      case Keyword.get(config, :net, :none) do
        :none ->
          [:clone_newnet | flags]

        :host ->
          flags
      end

    fn init ->
      case :prx.clone(init, flags) do
        {:ok, sh} ->
          {:ok, [Stdio.ProcessTree.task(sh)]}

        {:error, _} = error ->
          error
      end
    end
  end

  @impl true
  def onexit(_config) do
    # The shell process is the first process in the PID namespace:
    #
    # * calling :prx.pidof(sh) will return the PID in the global namespace
    #
    # * calling :prx.getpid(sh) will return the namespaced PID, e.g., 1
    #
    # * the supervisor process is in the global PID namespace
    #
    # * calling :prx.kill(init, pid) will attempt to kill PID 1 in the
    #   global namespace
    #
    # The direct parent of the process created the PID namespace.
    fn %Stdio.ProcessTree{supervisor: %Stdio{init: supervisor}, pipeline: [sh]} ->
      status = Stdio.Process.alive?(sh.task)
      _ = Stdio.Process.signal(supervisor, sh.pid, :SIGKILL)
      status
    end
  end

  @impl true
  def ops(config) do
    uid = Keyword.get(config, :uid, :erlang.phash2(self(), 0xFFFF) + 0x10000)
    gid = Keyword.get(config, :gid, uid)
    groups = Keyword.get(config, :groups, [])

    priv_dir = Stdio.__basedir__()

    path =
      Keyword.get(
        config,
        :path,
        Path.join(
          priv_dir,
          "root"
        )
      )

    fstab = Keyword.get(config, :fstab, [])

    hostname = Keyword.get(config, :hostname, "stdio#{uid}")

    [
      {:setsid, []},
      {:sethostname, [hostname]},
      {:setpriority, [:prio_process, 0, Keyword.get(config, :priority, 0)]},
      {:mount, ["none", "/", "", [:ms_rec, :ms_private], ""]},

      # pivot_root(2) requires `new_root` to be a mount point. Bind
      # mount the root directory over itself to create a mount point.
      {:mount, [path, path, "", [:ms_bind], ""]},
      {:prx, :mount, [path, path, "", [:ms_remount, :ms_bind, :ms_rdonly, :ms_nosuid], ""],
       [{:errexit, false}]},
      for dir <- [
            "/bin",
            "/sbin",
            "/usr",
            "/lib"
          ] do
        [
          {:mount, [dir, [path, dir], "", [:ms_bind], ""]},
          {:mount, [dir, [path, dir], "", [:ms_remount, :ms_bind, :ms_rdonly], ""]}
        ]
      end,
      for dir <- ["/lib64"] ++ fstab do
        sourcedir =
          case Path.type(dir) do
            :relative ->
              Path.join([priv_dir, dir])

            _ ->
              dir
          end

        destdir = Path.join([path, dir])

        [
          {:prx, :mount, [sourcedir, destdir, "", [:ms_bind], ""], [{:errexit, false}]},
          {:prx, :mount, [sourcedir, destdir, "", [:ms_remount, :ms_bind, :ms_rdonly], ""],
           [{:errexit, false}]}
        ]
      end,
      {:mount,
       [
         "tmpfs",
         [path, "/tmp"],
         "tmpfs",
         [:ms_noexec, :ms_nodev, :ms_noatime, :ms_nosuid],
         ["mode=1777,size=4M"]
       ]},
      {:mount,
       [
         "tmpfs",
         [path, "/home"],
         "tmpfs",
         [:ms_noexec, :ms_nodev, :ms_noatime, :ms_nosuid],
         ["uid=", Integer.to_string(uid), ",gid=", Integer.to_string(gid), ",mode=700,size=8M"]
       ]},

      # proc on /proc type proc (rw,noexec,nosuid,nodev)
      {:mount, ["proc", [path, "/proc"], "proc", [:ms_noexec, :ms_nosuid, :ms_nodev], ""]},
      {:chdir, [path]},
      {:pivot_root, [".", "."]},
      {:umount2, [".", [:mnt_detach]]},
      for {resource, rlim} <-
            Keyword.get(config, :rlimit, [
              {:rlimit_core, %{cur: 0, max: 0}}
            ]) do
        {:setrlimit, [resource, rlim]}
      end,
      {:setgroups, [groups]},
      {:setresgid, [gid, gid, gid]},
      {:setresuid, [uid, uid, uid]},
      if Keyword.get(config, :setuid, false) do
        []
      else
        Stdio.Syscall.os().disable_setuid()
      end,
      Stdio.Syscall.os().set_pdeathsig()
    ]
  end
end
