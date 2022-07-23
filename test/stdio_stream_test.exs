defmodule StdioStreamTest do
  use ExUnit.Case
  doctest Stdio.Stream

  setup do
    Stdio.__setuid__(false)
  end
end
