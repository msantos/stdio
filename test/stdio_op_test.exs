defmodule StdioOpTest do
  use ExUnit.Case

  setup_all do
    Stdio.__setuid__(false)
    {:ok, supervisor} = Stdio.supervisor()

    on_exit(fn -> :prx.stop(supervisor.init) end)

    %{supervisor: supervisor}
  end

  test "init: bad supervisor chain", config do
    supervisor = config.supervisor

    result =
      try do
        Stdio.Op.task!(
          supervisor,
          [],
          fn _ -> {:ok, []} end,
          Stdio.Process.onerror([])
        )
      catch
        kind, payload ->
          %{kind: kind, payload: payload}
      end

    assert :error = result.kind
    assert :eagain = result.payload.reason
  end

  test "init: return errno", config do
    supervisor = config.supervisor

    result =
      try do
        Stdio.Op.task!(
          supervisor,
          [],
          fn _ -> {:error, :eperm} end,
          Stdio.Process.onerror([])
        )
      catch
        kind, payload ->
          %{kind: kind, payload: payload}
      end

    assert :error = result.kind
    assert :eperm = result.payload.reason
  end

  test "op: return errno", config do
    supervisor = config.supervisor

    result =
      try do
        Stdio.Op.task!(
          supervisor,
          [
            [
              {__MODULE__, :__errno__, [:eoverflow]}
            ],
            {__MODULE__, :__ok__, []}
          ],
          Stdio.Process.init([]),
          Stdio.Process.onerror([])
        )
      catch
        kind, payload ->
          %{kind: kind, payload: payload}
      end

    assert :error = result.kind
    assert :eoverflow = result.payload.reason
  end

  test "op: ignore errno", config do
    supervisor = config.supervisor

    result =
      Stdio.Op.task!(
        supervisor,
        [
          [
            {__MODULE__, :__errno__, [:eoverflow], errexit: false},
            {:setuid, [0], errexit: false}
          ],
          {__MODULE__, :__ok__, []}
        ],
        Stdio.Process.init([]),
        Stdio.Process.onerror([])
      )

    assert [pid] = result
    :prx.stop(pid)
  end

  test "op: state", config do
    supervisor = config.supervisor

    result =
      Stdio.Op.task!(
        supervisor,
        [
          [
            {__MODULE__, :__ok_state__, [:ok]},
            {__MODULE__, :__op_with_state__, [], state: true}
          ],
          {__MODULE__, :__ok__, []}
        ],
        Stdio.Process.init([]),
        Stdio.Process.onerror([])
      )

    assert [pid] = result
    :prx.stop(pid)
  end

  test "op: return branch", config do
    supervisor = config.supervisor

    result =
      Stdio.Op.task!(
        supervisor,
        [
          {__MODULE__, :__op_returns_branch__, []}
        ],
        Stdio.Process.init([]),
        Stdio.Process.onerror([])
      )

    assert [pid] = result
    :prx.stop(pid)
  end

  def __ok__(_task), do: :ok
  def __ok_state__(_task, state), do: {:ok, state}
  def __errno__(_task, error), do: {:error, error}

  def __op_with_state__(:ok, task) when is_pid(task), do: :ok

  def __op_returns_branch__(_task),
    do: [
      {__MODULE__, :__ok__, []},
      {__MODULE__, :__ok__, []}
    ]
end
