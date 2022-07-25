defmodule Stdio.Procfs do
  @moduledoc "Read data from [procfs](https://man7.org/linux/man-pages/man5/proc.5.html)."

  @type t :: %{String.t() => String.t()}

  @procfs "/proc"

  @doc ~S"""
  Return a snapshot of the current system processes.

  Generates a snapshot of running system processes by walking the procfs
  filesystem (usually mounted as `/proc`).

  The returned value is a map list of key/value pairs read from
  `/proc/[pid]/status`.

  ## Examples

      iex> pid = Stdio.Procfs.ps() |> Enum.sort(&(&1["ppid"] < &2["ppid"])) |> List.first()
      iex> pid["pid"]
      "1"

  """
  @spec ps(Path.t()) :: [t]
  def ps(procfs \\ @procfs) do
    files = Path.wildcard(Path.join(procfs, "/[0-9]*/status"))
    status(files)
  end

  @spec status([String.t()]) :: [t]
  defp status(files), do: status(files, [])

  defp status([], pids), do: pids

  @spec status([String.t()], [t]) :: [t]
  defp status([file | files], pids) do
    case File.read(file) do
      {:ok, b} ->
        status(files, [procmap(b) | pids])

      {:error, _} ->
        status(files, pids)
    end
  end

  @spec procmap(String.t()) :: t
  defp procmap(buf) do
    buf
    |> String.split("\n")
    |> Enum.flat_map(fn
      "" ->
        []

      l ->
        # Pid:    13028
        # PPid:   13007
        [k, v] = String.split(l, ":\t", parts: 2, trim: true)
        [{String.downcase(k), String.trim(v)}]
    end)
    |> Enum.into(%{})
  end

  @doc ~S"""
  Get descendents of a process.

  Child processes are enumerated by reading `proc(5)`:

  * if the Linux kernel was compiled with `CONFIG_PROC_CHILDREN`, the
    `/proc/[pid]/task/[pid]/children` file is read

  * otherwise, `children/1` falls back to walking /proc

  ## Examples

      iex> Stdio.Procfs.children(0) |> Enum.sort() |> List.first()
      1

  """
  @spec children(:prx.pid_t(), Path.t()) :: [:prx.pid_t()]
  def children(pid, procfs \\ @procfs) do
    pidstr = "#{pid}"

    case File.read(Path.join([procfs, pidstr, "task", pidstr, "children"])) do
      {:ok, b} ->
        b
        |> String.split()
        |> Enum.map(fn p -> String.to_integer(p) end)

      {:error, _} ->
        walk([pidstr], ps(procfs), MapSet.new())
    end
  end

  @spec walk([String.t()], [t], MapSet.t()) :: [:prx.pid_t()]
  defp walk([], _, found),
    do: MapSet.to_list(found) |> Enum.map(fn pid -> String.to_integer(pid) end)

  defp walk([pid | rest], pids, found) do
    child =
      pids
      |> Enum.flat_map(fn
        %{"ppid" => ^pid} = p ->
          [p["pid"]]

        _ ->
          []
      end)

    case child do
      [] ->
        walk(rest, pids, found)

      _ ->
        walk(Enum.uniq(child ++ rest), pids, Enum.into(child, found))
    end
  end

  @spec __reap__(
          :prx.pid_t(),
          any,
          (term, any -> {Enumerable.t(), any} | {:halt, term}),
          Path.t()
        ) :: :ok
  def __reap__(pid, acc, reaper, procfs) do
    resourcefun = fn parent ->
      case children(parent, procfs) do
        [] -> {:halt, parent}
        pids -> {pids, parent}
      end
    end

    Stream.resource(
      fn -> pid end,
      resourcefun,
      fn _ -> :ok end
    )
    |> Stream.transform(acc, reaper)
    |> Stream.run()
  end
end
