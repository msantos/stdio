case :os.type() do
  {:unix, :linux} ->
    ExUnit.configure(exclude: [:freebsd, :openbsd])

  {:unix, :freebsd} ->
    ExUnit.configure(exclude: [:linux, :openbsd])

  {:unix, _} ->
    ExUnit.configure(exclude: :test, include: :process)
end

ExUnit.start()
