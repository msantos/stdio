defmodule Stdio.OpError do
  defexception [:reason, :message]

  @impl true
  def exception(opts) do
    reason = opts[:reason]

    case reason do
      :badop ->
        {m, f, a} = opts[:op]
        ops = opts[:ops]

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
        error = "#{:file.format_error(reason)} (#{reason})"

        %Stdio.OpError{
          message: "operation returned an error: #{error}",
          reason: reason
        }
    end
  end
end

defmodule Stdio.Op do
  @moduledoc "Run sequence of system calls on a process"

  def task(%Stdio{init: supervisor}, ops, initfun, terminatefun) do
    case initfun.(supervisor) do
      {:ok, []} ->
        {:error, :eagain}

      {:ok, init} ->
        run(supervisor, init, terminatefun, ops)
    end
  end

  defp run(supervisor, inits, terminatefun, ops) do
    init = List.last(inits)

    case :prx_task.with(init, ops, []) do
      :ok ->
        {:ok, inits}

      error ->
        terminatefun.(supervisor, init)
        error
    end
  end
end
