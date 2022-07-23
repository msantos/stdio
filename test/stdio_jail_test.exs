defmodule StdioJailTest do
  use ExUnit.Case

  @moduletag :freebsd
  doctest Stdio.Jail

  setup do
    Stdio.setuid()
  end
end
