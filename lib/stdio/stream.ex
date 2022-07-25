defmodule Stdio.StreamError do
  defexception [:reason, :message]

  @impl true
  def exception(opts) do
    reason = opts[:reason]
    action = opts[:action]
    cmd = opts[:cmd]

    errstr = "#{:file.format_error(reason)} (#{reason})"

    %Stdio.StreamError{
      message: "error creating #{action}: #{inspect(cmd)}: #{errstr}",
      reason: reason
    }
  end
end

defmodule Stdio.Stream do
  @moduledoc "Stream standard I/O from system processes"

  defstruct process: nil,
            stream_pid: nil,
            status: :running,
            flush_timeout: 0

  @type t :: %__MODULE__{
          process: Stdio.ProcessTree.t() | nil,
          stream_pid: pid | nil,
          status: :running | :flush | :flushing,
          flush_timeout: 0 | :infinity
        }

  defp stream_init(cmd, config, opsfun, initfun, onerrorfun, taskfun) do
    case taskfun.(config) do
      {:ok, supervisor} ->
        result =
          try do
            Stdio.__fork__(
              supervisor,
              cmd,
              config,
              opsfun,
              initfun,
              onerrorfun
            )
          rescue
            e ->
              Stdio.__atexit__(%Stdio.ProcessTree{supervisor: supervisor})
              reraise e, __STACKTRACE__
          end

        case result do
          {:ok, process} ->
            %Stdio.Stream{process: process}

          {:error, error} ->
            Stdio.__atexit__(%Stdio.ProcessTree{supervisor: supervisor})

            raise Stdio.StreamError,
              reason: error,
              action: "subprocess",
              cmd: cmd,
              config: config
        end

      {:error, error} ->
        raise Stdio.StreamError, reason: error, action: "supervisor", cmd: cmd, config: config
    end
  end

  def __stream__(cmd, config, opsfun, initfun, onerrorfun, taskfun) do
    startfun = fn ->
      stream_init(cmd, config, opsfun, initfun, onerrorfun, taskfun)
    end

    endfun = fn %Stdio.Stream{
                  process: process
                } ->
      Stdio.__atexit__(process)
    end

    Stream.resource(
      startfun,
      &stdio/1,
      endfun
    )
  end

  @spec pipe_stream(Enumerable.t(), pid) :: Enumerable.t()
  defp pipe_stream(stream, pid) do
    startfun = fn ->
      :ok
    end

    transformfun = fn
      <<>>, state ->
        {[], state}

      b, state ->
        Kernel.send(pid, {:stream_stdin, b})

        receive do
          :ok ->
            {[], state}
        end
    end

    endfun = fn _state ->
      Kernel.send(pid, :stream_eof)
      Process.unlink(pid)
    end

    Stream.transform(
      stream,
      startfun,
      transformfun,
      endfun
    )
  end

  defp pipe_init(stream, cmd, config, opsfun, initfun, onerrorfun, taskfun) do
    streamfun = fn pid ->
      fn ->
        stream
        |> pipe_stream(pid)
        |> Stream.run()
      end
    end

    case taskfun.(config) do
      {:ok, supervisor} ->
        result =
          try do
            Stdio.__fork__(
              supervisor,
              cmd,
              config,
              opsfun,
              initfun,
              onerrorfun
            )
          rescue
            e ->
              Stdio.__atexit__(%Stdio.ProcessTree{supervisor: supervisor})
              reraise e, __STACKTRACE__
          end

        case result do
          {:ok, process} ->
            stream_pid = Kernel.spawn_link(streamfun.(self()))

            %Stdio.Stream{
              process: process,
              stream_pid: stream_pid
            }

          {:error, error} ->
            Stdio.__atexit__(%Stdio.ProcessTree{supervisor: supervisor})

            raise Stdio.StreamError,
              reason: error,
              action: "subprocess",
              cmd: cmd,
              config: config
        end

      {:error, error} ->
        raise Stdio.StreamError, reason: error, action: "supervisor", cmd: cmd, config: config
    end
  end

  def __pipe__(stream, cmd, config, opsfun, initfun, onerrorfun, taskfun) do
    startfun = fn ->
      pipe_init(stream, cmd, config, opsfun, initfun, onerrorfun, taskfun)
    end

    endfun = fn
      %Stdio.Stream{
        process: process,
        stream_pid: nil
      } ->
        Stdio.__atexit__(process)

      %Stdio.Stream{
        process: process,
        stream_pid: stream_pid
      } ->
        Process.unlink(stream_pid)
        Process.exit(stream_pid, :kill)
        Stdio.__atexit__(process)
    end

    Stream.resource(
      startfun,
      &stdio/1,
      endfun
    )
  end

  defp stdio(
         %Stdio.Stream{
           process:
             %Stdio.ProcessTree{
               supervisor: %Stdio{init: init},
               pipeline: pipeline
             } = pstree,
           stream_pid: stream_pid,
           status: :running
         } = state
       ) do
    sh = List.last(pipeline)

    receive do
      :stream_eof ->
        parent = Stdio.ProcessTree.__supervisor__(pstree)

        # XXX supervisor chain: attempting to close the process stdin
        # XXX sometimes crashes:
        # XXX
        # XXX ** (exit) exited in: :gen_statem.call(#PID<0.604.0>, {:close, '\n'}, :infinity)
        # XXX   ** (EXIT) no process: the process is not alive or
        # XXX there's no process currently associated with the given name,
        # XXX possibly because its application isn't started
        result =
          try do
            :prx.eof(parent, sh)
          catch
            _, _ ->
              {:error, :esrch}
          end

        case result do
          :ok ->
            {[], state}

          # subprocess already exited
          {:error, :esrch} ->
            {[], %{state | status: :flush}}

          {:error, _} ->
            {[], %{state | status: :flush}}
        end

      {:stdout, ^sh, stdout} ->
        :prx.setcpid(sh, :flowcontrol, 1)
        {[{:stdout, stdout}], state}

      {:stderr, ^sh, stderr} ->
        :prx.setcpid(sh, :flowcontrol, 1)
        {[{:stderr, stderr}], state}

      # writes to stdin are asynchronous: errors are returned
      # as messages
      {:stdin, ^sh, error} ->
        {[{:stderr, "#{inspect(error)}"}], %{state | status: :flush}}

      {:signal, ^init, signal, _} ->
        Stdio.Procfs.children(:prx.getpid(init))
        |> Enum.each(fn pid ->
          :prx.kill(init, pid, signal)
        end)

        {[], state}

      {:signal, _, _, _} ->
        {[], state}

      # Forward signal to container process group
      {:EXIT, _, sig} ->
        case :prx.pidof(sh) do
          :noproc ->
            {[], %{state | status: :flush}}

          pid ->
            _ = :prx.kill(init, -pid, signal(sig))
            {[], %{state | status: :flush}}
        end

      {:stream_signal, sig} ->
        case :prx.pidof(sh) do
          :noproc ->
            {[], %{state | status: :flush}}

          pid ->
            _ = :prx.kill(init, -pid, signal(sig))
            {[], state}
        end

      {:stream_stdin, e} ->
        :ok = :prx.stdin(sh, e)
        Kernel.send(stream_pid, :ok)
        {[], state}

      {:exit_status, ^sh, status} ->
        {[{:exit_status, status}], %{state | status: :flush}}

      {:termsig, ^sh, sig} ->
        {[{:termsig, sig}], %{state | status: :flush}}
    end
  end

  defp stdio(
         %Stdio.Stream{
           process:
             %Stdio.ProcessTree{
               pipeline: pipeline
             } = pstree,
           stream_pid: nil,
           status: :flush
         } = state
       ) do
    # The shell process is in a PID namespace:
    #
    # * calling :prx.pidof(sh) will return the namespace PID, e.g., 2
    # * the supervisor process is in the global PID namespace
    # * calling :prx.kill(init, pid) will attempt to kill PID 2 in the
    #   global namespace
    #
    # The direct parent of the process created the PID namespace.
    parent = Stdio.ProcessTree.__supervisor__(pstree)
    sh = List.last(pipeline)

    flush_timeout =
      case :prx.pidof(sh) do
        :noproc ->
          0

        pid ->
          _ =
            case :prx.kill(parent, -pid, :SIGKILL) do
              {:error, :esrch} ->
                :prx.kill(parent, pid, :SIGKILL)

              _ ->
                :ok
            end

          :infinity
      end

    stdio(%{state | status: :flushing, flush_timeout: flush_timeout})
  end

  defp stdio(
         %Stdio.Stream{
           stream_pid: stream_pid,
           status: :flush
         } = state
       ) do
    Process.unlink(stream_pid)
    Process.exit(stream_pid, :kill)

    stdio(%{state | stream_pid: nil})
  end

  defp stdio(
         %Stdio.Stream{
           process: %Stdio.ProcessTree{
             pipeline: pipeline
           },
           status: :flushing,
           flush_timeout: flush_timeout
         } = state
       ) do
    sh = List.last(pipeline)

    receive do
      :stream_eof ->
        {[], state}

      {:stdout, ^sh, stdout} ->
        {[{:stdout, stdout}], state}

      {:stderr, ^sh, stderr} ->
        {[{:stderr, stderr}], state}

      {:stdin, ^sh, _error} ->
        {[], state}

      {:signal, _, _, _} ->
        {[], state}

      {:stream_stdin, _} ->
        {[], state}

      {:exit_status, ^sh, status} ->
        {[{:exit_status, status}], %{state | flush_timeout: 0}}

      {:termsig, ^sh, sig} ->
        {[{:termsig, sig}], %{state | flush_timeout: 0}}
    after
      flush_timeout ->
        {:halt, state}
    end
  end

  @doc ~S"""
  Combine standard error into the standard output of `Stdio.stream!/1`
  or `Stdio.pipe!/2` and emit a list of binaries.

  Exit status and termination signals are not included in the output.

  ## Examples

      iex> Stdio.stream!("echo output; echo error 1>&2; exit 1")
      ...> |> Stream.transform([], &Stdio.Stream.stdout_to_stderr/2)
      ...> |> Enum.to_list()
      ["output\n", "error\n"]

  """
  @spec stdout_to_stderr(Stdio.stdio(), term) :: {[binary] | :halt, term}
  def stdout_to_stderr({:stdout, t}, acc), do: {[t], acc}
  def stdout_to_stderr({:stderr, t}, acc), do: {[t], acc}
  def stdout_to_stderr({:exit_status, _}, acc), do: {:halt, acc}
  def stdout_to_stderr({:termsig, _}, acc), do: {:halt, acc}

  @doc ~S"""
  Rate limits a stream by discarding elements exceeding a threshold for
  the remainder of the window.

  `ratelimit/3` works with any `Enumerable.t`. For working with streams
  generated by `Stdio`, see `ratelimit/4`.

  ## Examples

      iex> Stream.unfold(1_000, fn 0 -> nil; n -> {n, n-1} end)
      ...> |> Stdio.Stream.ratelimit(2, 10_000)
      ...> |> Enum.to_list()
      [1000, 999]

  """
  @spec ratelimit(Enumerable.t(), pos_integer, pos_integer) :: Enumerable.t()
  def ratelimit(stream, limit, ms) do
    limitfun = fn
      e, %{count: count, limit: limit} = state when count <= limit ->
        {[e], %{state | count: count + 1}}

      e, %{t: t, ms: ms} = state ->
        now = System.monotonic_time(:millisecond)
        d = now - t

        case d < ms do
          true ->
            {[], state}

          false ->
            {[e], %{state | t: now, count: 1}}
        end

      e, state ->
        {[e], state}
    end

    ratelimit(stream, limit, ms, limitfun)
  end

  @doc """
  Rate limits a stream by calling a function on each event.

  The function is a reducer for `Stream.transform/3` which is passed
  the rate limit state in the accumulator:

  * t: window start time

  * limit: window threshold

  * ms: window duration in milliseconds

  The function maintains a count of matching events and enables rate
  limiting when the threshold is exceeded for the window.

  See `stdio_block/2` and `stdio_drop/2` for functions which can apply
  back pressure to or drop events from `Stdio.stream!/1` or `Stdio.pipe!/2`.
  """
  @spec ratelimit(
          Enumerable.t(),
          pos_integer,
          pos_integer,
          (term, acc -> {Enumerable.t(), acc} | {:halt, term})
        ) :: Enumerable.t()
        when acc: %{t: integer, limit: non_neg_integer, ms: non_neg_integer}
  def ratelimit(stream, limit, ms, limitfun) do
    startfun = fn ->
      %{t: System.monotonic_time(:millisecond), limit: limit, ms: ms, count: 1}
    end

    endfun = fn _state ->
      :ok
    end

    Stream.transform(
      stream,
      startfun,
      limitfun,
      endfun
    )
  end

  @doc ~S"""
  Apply back pressure on `Stdio.stream!/1` or `Stdio.pipe!/2` using
  `ratelimit/4` by blocking further reads if the rate of stdout/stderr
  exceeds the threshold.

  Output accumulates until the process pipe buffer is full. Further
  writes are blocked.

  Control events (process exit and termination signals) are not counted
  against the threshold.

  > #### Warning {: .warning}
  > When the rate limit is reached, the stream is blocked for the
  > remainder of the window, even if the system process has exited.

  To see how it works, try running:

      require Logger
      Stdio.stream!("while :; do date; done")
      |> Stdio.Stream.ratelimit(1, 5_000, &Stdio.Stream.stdio_block/2)
      |> Stream.each(fn t -> t |> inspect() |> Logger.info() end)
      |> Enum.take(15)


  The output from Logger will be spaced 5 seconds apart. The data from
  `Stdio.stream!/1` is buffered:

      00:11:56.410 [info]  {:stdout, "Thu Jul  7 00:11:51 EDT 2022\n"}
      00:12:01.410 [info]  {:stdout, "Thu Jul  7 00:11:51 EDT 2022\n"}
      00:12:06.412 [info]  {:stdout, "Thu Jul  7 00:11:51 EDT..."}

  ## Examples

      iex> Stdio.stream!("echo 1")
      ...> |> Stdio.Stream.ratelimit(1, 2_000, &Stdio.Stream.stdio_block/2)
      ...> |> Enum.to_list()
      [stdout: "1\n", exit_status: 0]

  """
  def stdio_block({io, _} = e, %{count: count, limit: limit} = state)
      when (io == :stdout or io == :stderr) and count <= limit,
      do: {[e], %{state | count: count + 1}}

  def stdio_block({io, _} = e, %{t: t, ms: ms} = state) when io == :stdout or io == :stderr do
    now = System.monotonic_time(:millisecond)
    d = now - t
    if d < ms, do: Process.sleep(ms - d)
    {[e], %{state | t: now + (ms - d), count: 1}}
  end

  def stdio_block(e, state), do: {[e], state}

  @doc ~S"""
  Rate limit output of `Stdio.stream!/1` or `Stdio.pipe!/2` using
  `ratelimit/4` by dropping events if the rate of stdout/stderr exceeds
  the threshold.

  Control events (process exit and termination signals) are always
  passed through.

  To see how it works, try running:

      require Logger
      Stdio.stream!("while :; do date; done")
      |> Stdio.Stream.ratelimit(1, 5_000, &Stdio.Stream.stdio_drop/2)
      |> Stream.each(fn t -> t |> inspect() |> Logger.info() end)
      |> Enum.take(15)

  The output from Logger will be spaced 5 seconds apart. Rate limited
  data from `Stdio.stream!/1` is dropped:

      00:17:22.058 [info]  {:stdout, "Thu Jul  7 00:17:22 EDT 2022\n"}
      00:17:27.059 [info]  {:stdout, "Thu Jul  7 00:17:27 EDT 2022\n"}
      00:17:32.060 [info]  {:stdout, "Thu Jul  7 00:17:32 EDT 2022\n"}
      00:17:37.061 [info]  {:stdout, "Thu Jul  7 00:17:37 EDT 2022\n"}

  ## Examples

      iex> Stdio.stream!("echo 1")
      ...> |> Stdio.Stream.ratelimit(1, 2_000, &Stdio.Stream.stdio_drop/2)
      ...> |> Enum.to_list()
      [stdout: "1\n", exit_status: 0]

  """
  def stdio_drop({io, _} = e, %{count: count, limit: limit} = state)
      when (io == :stdout or io == :stderr) and count <= limit,
      do: {[e], %{state | count: count + 1}}

  def stdio_drop({io, _} = e, %{t: t, ms: ms} = state) when io == :stdout or io == :stderr do
    now = System.monotonic_time(:millisecond)
    d = now - t

    case d < ms do
      true ->
        {[], state}

      false ->
        {[e], %{state | t: now, count: 1}}
    end
  end

  def stdio_drop(e, state), do: {[e], state}

  defp signal(:normal), do: :SIGTERM
  defp signal(:kill), do: :SIGKILL
  defp signal(sig) when is_integer(sig), do: sig
  defp signal(sig) when is_atom(sig), do: sig
  defp signal(_), do: :SIGKILL
end
