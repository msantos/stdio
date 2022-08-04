defmodule Stdio.Rootless do
  use Stdio

  @moduledoc ~S"""
  Linux processes running in a user namespace.

  Proof of concept behaviour to run "rootless" Linux
  processes or processes that have root privileges in a [user
  namespace](https://man7.org/linux/man-pages/man7/user_namespaces.7.html).

  ## Privileges

  No extra privileges are required but user namespaces must be enabled
  on your platform:

      $ sysctl kernel.unprivileged_userns_clone
      kernel.unprivileged_userns_clone = 1

      # to enable:
      $ sysctl -w kernel.unprivileged_userns_clone=1

  ## Operations

  > #### Mount Namespace Root (chroot) Directory {: .info}
  > The chroot directory structure must be created before using this
  > behaviour.
  >
  > See `Stdio.Container.make_chroot_tree!/0` and
  > `Stdio.Container.make_chroot_tree!/1`.

  See `t:Stdio.config/0` for configuration options.

  ## Examples

      iex> Stdio.stream!("pstree", Stdio.Rootless) |> Enum.to_list()
      [stdout: "Supervise---sh---pstree\n", exit_status: 0]

      iex(1)> Stdio.stream!("ip --oneline -4 addr show dev lo", Stdio.Rootless, net: :host, setuid: true) |> Enum.to_list()
      [
        stdout: "1: lo    inet 127.0.0.1/8 scope host lo\\       valid_lft forever preferred_lft forever\n",
        exit_status: 0
      ]

  """

  @impl true
  def task(_config) do
    Stdio.supervisor(
      :noreap,
      {:allow,
       [
         # standard calls for supervisors: excludes fork
         :clone,
         :close,
         :exit,
         :getpid,
         :kill,
         :setcpid,
         :sigaction,

         # lookup UID/GID for user map in /proc/[pid]/{uid_map,gid_map}
         :getgid,
         :getuid
       ]}
    )
  end

  @impl true
  def init(config) do
    flags = [
      :clone_newipc,
      :clone_newns,
      :clone_newpid,
      :clone_newuts,
      :clone_newuser
    ]

    flags =
      case Keyword.get(config, :net, :none) do
        :none -> [:clone_newnet | flags]
        :host -> flags
      end

    uid = Keyword.get(config, :uid, 65_534)
    gid = Keyword.get(config, :gid, uid)

    fn init ->
      ruid = :prx.getuid(init)
      rgid = :prx.getgid(init)

      # Fork the container init, cleanup resources on error
      case :prx.clone(init, flags) do
        {:ok, cinit} ->
          with :ok <- write_file(cinit, "/proc/self/uid_map", "#{uid} #{ruid} 1\n"),
               :ok <- write_file(cinit, "/proc/self/setgroups", "deny"),
               :ok <- write_file(cinit, "/proc/self/gid_map", "#{gid} #{rgid} 1\n"),
               {:ok, _} <- Stdio.supervise(cinit) do
            case :prx.fork(cinit) do
              {:ok, sh} ->
                {:ok, [Stdio.ProcessTree.task(cinit), Stdio.ProcessTree.task(sh)]}

              {:error, _} = error ->
                :prx.stop(cinit)
                error
            end
          else
            {:error, _} = error ->
              :prx.stop(cinit)
              error
          end

        {:error, _} = error ->
          error
      end
    end
  end

  @impl true
  def onexit(_config) do
    # The shell process is in a PID namespace:
    #
    # * calling :prx.pidof(sh) will return the namespace PID, e.g., 2
    #
    # * the supervisor process is in the global PID namespace
    #
    # * calling :prx.kill(init, pid) will attempt to kill PID 2 in the
    #   global namespace
    #
    # The direct parent of the process created the PID namespace.
    fn %Stdio.ProcessTree{supervisor: %Stdio{init: supervisor}, pipeline: [init, sh]} ->
      alive = Stdio.Process.alive?(init.task)
      status = alive and Stdio.Process.alive?(sh.task)

      _ =
        case alive do
          true ->
            # namespace: signal the PID namespace
            :prx.kill(init.task, -1, :SIGKILL)

          false ->
            # global: signal the init process
            Stdio.Process.signal(supervisor, init.pid, :SIGKILL)
        end

      status
    end
  end

  @impl true
  def ops(config) do
    hostname = Keyword.get(config, :hostname, "stdio")
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

    [
      {:setsid, []},
      {:sethostname, [hostname]},
      {:setpriority, [:prio_process, 0, Keyword.get(config, :priority, 0)]},

      # pivot_root(2) requires `new_root` to be a mount point. Bind
      # mount the root directory over itself to create a mount point.
      {:mount, ["none", "/", "", [:ms_rec, :ms_private], ""]},
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
         ["mode=700,size=8M"]
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
      if Keyword.get(config, :setuid, false) do
        []
      else
        Stdio.Syscall.os().disable_setuid()
      end,
      Stdio.Syscall.os().set_pdeathsig()
    ]
  end

  # Let the file descriptor leak if write or close fails: the process
  # will exit on error.
  defp write_file(task, file, buf) do
    with {:ok, fd} <- :prx.open(task, file, [:o_rdwr]),
         {:ok, _} <- :prx.write(task, fd, buf) do
      :prx.close(task, fd)
    end
  end
end
