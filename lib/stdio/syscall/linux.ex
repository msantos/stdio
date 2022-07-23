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
end
