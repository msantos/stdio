defmodule Stdio.OpError do
  defexception [:reason, :message]

  @impl true
  def exception(opts) do
    reason = opts[:reason]
    {m, f, a} = opts[:op]
    ops = opts[:ops]

    case reason do
      :badinit ->
        error = opts[:error]

        %Stdio.OpError{
          message: """
          error attempting to fork subprocess: #{errno(error)}
          """,
          reason: error
        }

      :badop ->
        error =
          case opts[:error] do
            {:reason, invalid} ->
              Exception.format(:error, {:badmatch, invalid}, [{m, f, a, []}])

            {:reason, kind, payload} ->
              Exception.format(kind, payload, [{m, f, a, []}])
          end

        %Stdio.OpError{
          message: """
          #{error}

          remaining ops:
          #{inspect(ops, pretty: true)}
          """,
          reason: reason
        }

      _ ->
        op = Exception.format_mfa(m, f, a)

        %Stdio.OpError{
          message: """
          operation returned an error: #{errno(reason)}

          #{op}

          remaining ops:
          #{inspect(ops, pretty: true)}
          """,
          reason: reason
        }
    end
  end

  defp errno(:eperm), do: "insufficient permissions (eperm)"
  defp errno(error), do: "#{:file.format_error(error)} (#{error})"
end

defmodule Stdio.Op do
  @moduledoc "Run a sequence of system calls on a process"

  @typedoc """
  Operations consist of a list of tuples containing:

  * an optional module name (default: `:prx`)
  * a function name
  * a list of arguments
  * an optional list of options to modify the behaviour of the operation
    (see `t:option`)

  ## Examples

      {:setresuid, [1000,1000,1000]}
      {:prx, :setresuid, [1000,1000,1000]}
      {:prx, :setresuid, [1000,1000,1000], errexit: false}

  """
  @type t ::
          {atom(), list()}
          | {module(), atom(), list()}
          | {module(), atom(), list(), [option()]}

  @typedoc """
  Options to modify the behavior of an operation:

  * `state`: pass `ok` result as the first parameter to the next
     operation (default: false)

  * `errexit`: abort operations on error (default: true)

  * `transform`: abort operations on error (default: true)
  """
  @type option ::
          {:state, boolean()}
          | {:errexit, boolean()}
          | {:state, boolean()}
          | {:errexit, boolean()}
          | {:transform, (any() -> :ok | {:ok, state :: any()} | {:error, :prx.posix()})}

  @doc """
  Creates and configures a new process from the supervisor process.
  """
  @spec task!(
          Stdio.t(),
          ops :: [t | [t]],
          (init :: :prx.task() ->
             {:ok, pipeline :: Stdio.pipeline()} | {:error, :prx.posix()}),
          (sh :: :prx.task() -> any)
        ) :: Stdio.pipeline()
  def task!(%Stdio{init: supervisor}, ops, initfun, onerrorfun)
      when is_pid(supervisor) do
    case initfun.(supervisor) do
      {:ok, []} ->
        raise Stdio.OpError,
          reason: :badinit,
          op: {Stdio, :init, []},
          error: :eagain

      {:ok, init} ->
        run!(init, onerrorfun, ops)

      {:error, error} ->
        raise Stdio.OpError,
          reason: :badinit,
          op: {Stdio, :init, []},
          error: error
    end
  end

  @spec run!(
          Stdio.pipeline(),
          (sh :: :prx.task() -> any),
          [t | [t]]
        ) :: Stdio.pipeline()
  defp run!(inits, onerrorfun, ops) do
    init = List.last(inits).task

    case seq(init, ops, []) do
      :ok ->
        inits

      {:error, {error, {mod, fun, arg}, ops}} ->
        onerrorfun.(init)

        raise Stdio.OpError,
          reason: error,
          op: {mod, fun, arg},
          ops: ops,
          error: error
    end
  end

  @spec seq(:prx.task(), ops :: [t | [t]], state :: any()) ::
          :ok | {:error, any()}
  defp seq(_task, [], _State), do: :ok

  defp seq(task, [op | ops], state) when is_list(op) do
    case seq(task, op, state) do
      :ok ->
        seq(task, ops, state)

      {:error, _} = error ->
        error
    end
  end

  defp seq(task, [{fun, arg} | ops], state) do
    op(task, :prx, fun, [task | arg], [], ops, state)
  end

  defp seq(task, [{fun, arg, options} | ops], state)
       when is_atom(fun) and is_list(arg) and is_list(options) do
    seq(task, [{:prx, fun, arg, options} | ops], state)
  end

  defp seq(task, [{mod, fun, arg} | ops], state) when is_atom(mod) and is_atom(fun) do
    op(task, mod, fun, [task | arg], [], ops, state)
  end

  defp seq(task, [{mod, fun, arg0, options} | ops], state) do
    argv_with_state = Keyword.get(options, :state, false)

    arg =
      case argv_with_state do
        true -> [state, task | arg0]
        false -> [task | arg0]
      end

    op(task, mod, fun, arg, options, ops, state)
  end

  defp op(task, mod, fun, arg, options, ops, state) do
    exit = Keyword.get(options, :errexit, true)
    transform = Keyword.get(options, :transform, fn t -> t end)

    result =
      try do
        transform.(Kernel.apply(mod, fun, arg))
      catch
        kind, payload ->
          raise Stdio.OpError,
            reason: :badop,
            op: {mod, fun, arg},
            ops: ops,
            error: {:reason, kind, payload}
      end

    case result do
      :ok ->
        seq(task, ops, state)

      {:ok, new_state} ->
        seq(task, ops, new_state)

      branch when is_list(branch) ->
        seq(task, branch, state)

      {:error, _} when not exit ->
        seq(task, ops, state)

      {:error, error} ->
        {:error, {error, {mod, fun, arg}, ops}}

      unmatched ->
        raise Stdio.OpError,
          reason: :badop,
          op: {mod, fun, arg},
          ops: ops,
          error: {:reason, unmatched}
    end
  end
end
