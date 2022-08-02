defmodule Stdio.Syscall.Linux do
  @moduledoc ~S"""
  System call portability for Linux.
  """
  use Stdio.Syscall

  # Overwrite arg0 and `/proc/self/comm` with the new process title.
  @impl true
  def setproctitle(task, title) do
    with {:ok, _, _, _, _, _} <-
           :prx.prctl(task, :pr_set_name, title, 0, 0, 0) do
      :prx.setproctitle(task, title)
    end
  end

  @impl true
  def subreaper(task) do
    with {:ok, _, _, _, _, _} <-
           :prx.prctl(task, :PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) do
      :ok
    end
  end

  @impl true
  def disable_setuid(),
    do: [
      {:prx, :prctl, [:PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0],
       [
         {:transform,
          fn
            {:ok, _, _, _, _, _} -> :ok
            {:error, _} = error -> error
          end}
       ]}
    ]

  @impl true
  def set_pdeathsig(),
    do: [
      {:prx, :prctl, [:PR_SET_PDEATHSIG, 9, 0, 0, 0],
       [
         {:transform,
          fn
            {:ok, _, _, _, _, _} -> :ok
            {:error, _} = error -> error
          end}
       ]}
    ]

  @doc """
  Terminating descendents of a supervisor process
  """
  @impl true
  def reap(%Stdio.ProcessTree{supervisor: %Stdio{init: supervisor}} = pstree, signal),
    do: reap(pstree, :prx.getpid(supervisor), signal)

  @doc ~S"""
  Terminate descendents of a process.

  reap signals subprocesses of a process identified by PID. If the
  process called `PR_SET_CHILD_SUBREAPER`, background and daemonized
  subprocesses will also be terminated.

  Note: terminating subprocesses using this method is subject to race
  conditions:

  * new processes may have been forked

  * processes may have exited and unrelated processes assigned the PID

  * processes may ignore some signals

  * processes may not immediately exit after signalling
  """
  @impl true
  def reap(%Stdio.ProcessTree{supervisor: %Stdio{init: supervisor}}, pid, signal) do
    reaper = fn
      subprocess, count ->
        case :prx.kill(supervisor, subprocess, signal) do
          :ok ->
            {[], count + 1}

          {:error, :esrch} ->
            # subprocess exited
            {[], count + 1}

          {:error, _} ->
            # einval: invalid signal
            # eperm: user does not have permission to signal process
            # other: unexpected error: an undocumented value for errno, probably
            # an internal error
            {:halt, count}
        end
    end

    procfs = Application.get_env(:stdio, :procfs, procfs())
    Stdio.Procfs.__reap__(pid, 0, reaper, procfs)
  end
end
