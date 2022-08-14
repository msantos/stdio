defmodule Stdio.Process do
  @behaviour Stdio

  @moduledoc ~S"""
  Supervised system processes

  `fork(2)` new system processes.

  ## Privileges

  No additional privileges required. If the `Stdio` supervisor process
  is running as root, supervised processes will by default drop to an
  unprivileged user.

  ## Operations

  See `t:Stdio.config/0` for configuration options.

  * creates a new session

  * sets the process priority [:priority=0]

  * sets resource limits defined in the `rlimit` option [:rlimit=coredumps
    disabled]

  * sends the process a SIGKILL if the parent process exits

  If the system process is running with root privileges:

  * sets additional groups as specified in the `group` option
    [:groups=additional groups removed]

  * drops privileges to the value of `uid` and `gid` or a high UID system
    [:uid/gid=65536-131071]

  * disables the ability of the process to escalate privileges [:setuid=false]

  > #### Warning {: .warning}
  > The generated UID/GID may overlap with existing users.

  ## Examples

      iex> Stdio.stream!(
      ...> "ping -q -c 1 127.0.0.1 | grep -o PING",
      ...> Stdio.Process,
      ...> setuid: true
      ...> ) |> Enum.to_list()
      [stdout: "PING\n", exit_status: 0]

  """

  @doc """
  Signal a process by process group, falling back to PID
  """
  @spec signal(:prx.task(), :prx.pid_t(), pos_integer | atom) :: :ok | {:error, :prx.posix()}
  def signal(task, pid, signal) when pid > 0 do
    case :prx.kill(task, -pid, signal) do
      {:error, :esrch} ->
        :prx.kill(task, pid, signal)

      _ ->
        :ok
    end
  end

  @doc """
  Test if a Stdio process is running
  """
  # Tests if the system process is running:
  #
  # Using Process.alive?/1 would have a race condition where the elixir
  # process exists but the system process has exited.
  @spec alive?(:prx.task()) :: boolean
  def alive?(task) do
    case :prx.pidof(task) do
      :noproc ->
        false

      _ ->
        true
    end
  end

  @impl true
  def task(_config), do: Stdio.supervisor()

  @impl true
  def init(config), do: Stdio.Syscall.os().subprocess(config)

  @impl true
  def onerror(_config) do
    fn sh ->
      :prx.stop(sh)
    end
  end

  @impl true
  def onexit(_config) do
    fn %Stdio.ProcessTree{
         supervisor: %Stdio{init: supervisor},
         pipeline: pipeline
       } ->
      sh = List.last(pipeline)

      status = alive?(sh.task)
      _ = signal(supervisor, sh.pid, :SIGKILL)
      status
    end
  end

  @impl true
  def ops(config) do
    uid = Keyword.get(config, :uid, :erlang.phash2(self(), 0xFFFF) + 0x10000)
    gid = Keyword.get(config, :gid, uid)
    groups = Keyword.get(config, :groups, [])
    path = Keyword.get(config, :path, File.cwd!())

    [
      {:setsid, []},
      {:setpriority, [:prio_process, 0, Keyword.get(config, :priority, 0)]},
      {:chdir, [path]},
      for {resource, rlim} <-
            Keyword.get(config, :rlimit, [
              {:rlimit_core, %{cur: 0, max: 0}}
            ]) do
        {:setrlimit, [resource, rlim]}
      end,
      {__MODULE__, :__setugid__, [uid, gid, groups]},
      if Keyword.get(config, :setuid, false) do
        []
      else
        [
          Stdio.Syscall.os().disable_setuid()
        ]
      end,
      Stdio.Syscall.os().set_pdeathsig()
    ]
  end

  def __setugid__(task, uid, gid, groups) do
    case :prx.getuid(task) do
      0 ->
        [
          {:setgroups, [groups]},
          {:setresgid, [gid, gid, gid]},
          {:setresuid, [uid, uid, uid]}
        ]

      _ ->
        []
    end
  end
end
