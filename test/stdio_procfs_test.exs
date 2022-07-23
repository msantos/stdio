defmodule StdioProcfsTest do
  use ExUnit.Case

  @moduletag :linux
  doctest Stdio.Procfs

  setup do
    Stdio.__setuid__(false)
  end

  test "ps: get process table" do
    result = Stdio.Procfs.ps()
    [%{"ppid" => ppid, "pid" => pid} | _] = result
    assert String.to_integer(ppid) > 0
    assert String.to_integer(pid) > 1
  end
end
