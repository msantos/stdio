defmodule Stdio.Syscall do
  @moduledoc ~S"""
  System call portability for operating systems.
  """

  @doc """
  Set the process title.
  """
  @callback setproctitle(:prx.task(), String.t()) :: :ok | {:error, :prx.posix()}

  @doc """
  Set process as init(1) for descendent processes.
  """
  @callback subreaper(:prx.task()) :: :ok | {:error, :prx.posix()}

  @doc """
  Terminate descendents of a supervisor process.
  """
  @callback reap(Stdio.ProcessTree.t(), atom) :: :ok | {:error, :prx.posix()}

  @doc """
  Terminate a process subtree (descendents of a child process) of the supervisor.
  """
  @callback reap(Stdio.ProcessTree.t(), :prx.pid_t(), atom) :: :ok | {:error, :prx.posix()}

  @doc """
  Path to procfs file system
  """
  @callback procfs() :: String.t()

  @doc """
  Operations required to disable setuid.
  """
  @callback disable_setuid() :: [Stdio.Op.t()]

  @doc """
  Operations required to terminate a process if the parent exits.
  """
  @callback set_pdeathsig() :: [Stdio.Op.t()]

  @doc false
  defmacro __using__(_) do
    quote location: :keep do
      @behaviour Stdio.Syscall

      @doc false
      def setproctitle(task, title), do: Stdio.Syscall.setproctitle(task, title)

      @doc false
      def subreaper(task), do: Stdio.Syscall.subreaper(task)

      @doc false
      def procfs(), do: Stdio.Syscall.procfs()

      @doc false
      def reap(task, signal), do: Stdio.Syscall.reap(task, signal)

      @doc false
      def reap(task, pid, signal), do: Stdio.Syscall.reap(task, pid, signal)

      @doc false
      def disable_setuid(), do: []

      @doc false
      def set_pdeathsig(), do: []

      defoverridable setproctitle: 2,
                     subreaper: 1,
                     procfs: 0,
                     reap: 2,
                     reap: 3,
                     disable_setuid: 0,
                     set_pdeathsig: 0
    end
  end

  @doc """
  The default implementation for `c:setproctitle/2`

  Uses `:prx.setproctitle/2` on all platforms.
  """
  def setproctitle(task, title) do
    :prx.setproctitle(task, title)
  end

  @doc """
  The default implementation for `c:subreaper/1`

  No changes are made to the process: background processes will not
  be terminated.
  """
  def subreaper(_task) do
    :ok
  end

  @doc """
  The default implementation for `c:procfs/0`
  """
  def procfs(), do: "/proc"

  @doc """
  Terminating descendents of a supervisor process
  """
  def reap(
        %Stdio.ProcessTree{supervisor: %Stdio{init: supervisor}, pipeline: [%{pid: pid}]},
        signal
      ) do
    signal(supervisor, pid, signal)
  end

  def reap(%Stdio.ProcessTree{supervisor: %Stdio{init: supervisor}, pipeline: pipeline}, signal) do
    pipeline
    |> Enum.reverse()
    |> Enum.each(fn task ->
      case :prx.parent(task.task) do
        :noproc ->
          signal(supervisor, task.pid, signal)

        pid ->
          signal(pid, task.pid, signal)
      end
    end)
  end

  @doc ~S"""
  Terminate descendents of a process.

  Signals the process group for each child process.
  """
  def reap(
        %Stdio.ProcessTree{supervisor: %Stdio{init: supervisor}, pipeline: pipeline},
        pid,
        signal
      ) do
    result =
      pipeline
      |> Enum.reduce({[], false}, fn
        %{pid: ^pid} = task, {_, false} ->
          {[task], true}

        task, {acc, true} ->
          {[task | acc], true}

        _, {acc, false} ->
          {acc, false}
      end)

    case result do
      {_, false} ->
        {:error, :esrch}

      {pids, true} ->
        pids
        |> Enum.each(fn task ->
          signal(supervisor, task.pid, signal)
        end)
    end
  end

  defp signal(task, pid, sig) do
    case :prx.kill(task, -pid, sig) do
      {:error, :esrch} ->
        :prx.kill(task, pid, sig)

      {:error, _} = error ->
        error

      :ok ->
        :ok
    end
  end

  @doc """
  The default implementation for `c:disable_setuid/0`

  Disabling the ability for the process to escalate privileges is not
  available on this platform.
  """
  def disable_setuid(), do: []

  @doc """
  The default implementation for `c:set_pdeathsig/0`

  Signalling a process when the parent has exited is not available on
  this platform.
  """
  def set_pdeathsig(), do: []

  @doc """
  Get the syscall implementation for this platform.

  The default implementation is based on the operating system.

  Set the implementation by configuring the application environment:

      import Config

      config :stdio, :syscall, Stdio.Syscall.Linux
  """
  @spec os() :: module()
  def os(), do: Application.get_env(:stdio, :syscall, implementation())

  defp implementation() do
    case :os.type() do
      {:unix, :linux} -> Stdio.Syscall.Linux
      {:unix, :freebsd} -> Stdio.Syscall.FreeBSD
      {:unix, :openbsd} -> Stdio.Syscall.OpenBSD
      _ -> Stdio.Syscall
    end
  end
end
