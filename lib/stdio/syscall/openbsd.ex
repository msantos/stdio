defmodule Stdio.Syscall.OpenBSD do
  @moduledoc ~S"""
  System call portability for OpenBSD.
  """
  use Stdio.Syscall

  @pledgenames "stdio rpath wpath cpath dpath tmppath \
                inet mcast fattr chown flock unix dns getpw \
                sendfd recvfd tape tty proc exec prot_exec \
                settime ps vminfo id pf route wroute \
                audio video bpf unveil error disklabel \
                drm vmm"

  # Remove the capability of the process to escalate privileges as a
  # side effect of allowing all pledge names using `pledge(2)`.
  @impl true
  def disable_setuid(),
    do: [
      {:pledge, [@pledgenames, []]}
    ]
end
