defmodule Stdio.Syscall.FreeBSD do
  @moduledoc ~S"""
  System call portability for FreeBSD
  """
  use Stdio.Syscall

  @doc """
  FreeBSD procfs support using the Linux compatible procfs.

  See [linprocfs](https://www.freebsd.org/cgi/man.cgi?linprocfs(5))
  """
  @impl true
  def procfs(), do: "/compat/linux/proc"

  @impl true
  def subreaper(task) do
    with {:ok, _, _} <-
           :prx.procctl(task, 0, 0, :PROC_REAP_ACQUIRE, []) do
      :ok
    end
  end

  @impl true
  def reap(%Stdio.ProcessTree{supervisor: %Stdio{init: supervisor}}, signal) do
    with {:ok, signum} <- signal_constant(signal),
         cstruct = procctl_reaper_kill(signum),
         {:ok, _, _} <-
           :prx.procctl(supervisor, 0, 0, :PROC_REAP_KILL, cstruct) do
      :ok
    end
  end

  @reaper_kill_subtree 0x00000002

  @impl true
  def reap(%Stdio.ProcessTree{supervisor: %Stdio{init: supervisor}}, pid, signal) do
    with {:ok, signum} <- signal_constant(signal),
         cstruct = procctl_reaper_kill(signum, @reaper_kill_subtree, pid),
         {:ok, _, _} <-
           :prx.procctl(supervisor, 0, 0, :PROC_REAP_KILL, cstruct) do
      :ok
    end
  end

  @spec procctl_reaper_kill(1..255, 0 | 2, :prx.pid_t()) :: :prx.cstruct()
  defp procctl_reaper_kill(signum, flags \\ 0, pid \\ 0) do
    # struct procctl_reaper_kill {
    #         int     rk_sig;
    #         u_int   rk_flags;
    #         pid_t   rk_subtree;
    #         u_int   rk_killed;
    #         pid_t   rk_fpid;
    # };
    [
      <<signum::32-native>>,
      <<flags::32-native>>,
      <<pid::32-native>>,
      <<0::32>>,
      <<0::32>>
    ]
  end

  @impl true
  def disable_setuid(),
    do: [
      {:prx, :procctl, [:P_PID, 0, :PROC_NO_NEW_PRIVS_CTL, [<<1::32-native>>]],
       [
         {:transform,
          fn
            {:ok, _, _} -> :ok
            {:error, _} = error -> error
          end}
       ]}
    ]

  @spec signal_constant(atom) :: {:ok, 1..255} | {:error, :einval}
  defp signal_constant(signal) do
    case signum(signal) do
      :unknown -> {:error, :einval}
      n when is_integer(n) -> {:ok, n}
    end
  end

  # Return the signal number for a signal name.
  #
  # Equivalent to:
  #
  #   :prx.call(task, :signal_constant, [signal])
  #
  # But does not requiring adding call/3 to the init call allowlist.
  @spec signum(atom) :: 1..255 | :unknown
  defp signum(:SIGHUP), do: 1
  defp signum(:SIGINT), do: 2
  defp signum(:SIGQUIT), do: 3
  defp signum(:SIGILL), do: 4
  defp signum(:SIGTRAP), do: 5
  defp signum(:SIGABRT), do: 6
  defp signum(:SIGEMT), do: 7
  defp signum(:SIGFPE), do: 8
  defp signum(:SIGKILL), do: 9
  defp signum(:SIGBUS), do: 10
  defp signum(:SIGSEGV), do: 11
  defp signum(:SIGSYS), do: 12
  defp signum(:SIGPIPE), do: 13
  defp signum(:SIGALRM), do: 14
  defp signum(:SIGTERM), do: 15
  defp signum(:SIGURG), do: 16
  defp signum(:SIGSTOP), do: 17
  defp signum(:SIGTSTP), do: 18
  defp signum(:SIGCONT), do: 19
  defp signum(:SIGCHLD), do: 20
  defp signum(:SIGTTIN), do: 21
  defp signum(:SIGTTOU), do: 22
  defp signum(:SIGIO), do: 23
  defp signum(:SIGXCPU), do: 24
  defp signum(:SIGXFSZ), do: 25
  defp signum(:SIGVTALRM), do: 26
  defp signum(:SIGPROF), do: 27
  defp signum(:SIGWINCH), do: 28
  defp signum(:SIGINFO), do: 29
  defp signum(:SIGUSR1), do: 30
  defp signum(:SIGUSR2), do: 31

  defp signum(:sighup), do: 1
  defp signum(:sigint), do: 2
  defp signum(:sigquit), do: 3
  defp signum(:sigill), do: 4
  defp signum(:sigtrap), do: 5
  defp signum(:sigabrt), do: 6
  defp signum(:sigemt), do: 7
  defp signum(:sigfpe), do: 8
  defp signum(:sigkill), do: 9
  defp signum(:sigbus), do: 10
  defp signum(:sigsegv), do: 11
  defp signum(:sigsys), do: 12
  defp signum(:sigpipe), do: 13
  defp signum(:sigalrm), do: 14
  defp signum(:sigterm), do: 15
  defp signum(:sigurg), do: 16
  defp signum(:sigstop), do: 17
  defp signum(:sigtstp), do: 18
  defp signum(:sigcont), do: 19
  defp signum(:sigchld), do: 20
  defp signum(:sigttin), do: 21
  defp signum(:sigttou), do: 22
  defp signum(:sigio), do: 23
  defp signum(:sigxcpu), do: 24
  defp signum(:sigxfsz), do: 25
  defp signum(:sigvtalrm), do: 26
  defp signum(:sigprof), do: 27
  defp signum(:sigwinch), do: 28
  defp signum(:siginfo), do: 29
  defp signum(:sigusr1), do: 30
  defp signum(:sigusr2), do: 31

  defp signum(_), do: :unknown
end
