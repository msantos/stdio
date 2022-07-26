defmodule Stdio.Jail do
  use Stdio

  @moduledoc ~S"""
  Jailed FreeBSD processes

  Runs a process in a
  [jail(2)](https://www.freebsd.org/cgi/man.cgi?jail(2)).

  ## Privileges

  To use this behaviour, the system process supervisor must have root
  privileges. These privileges are dropped before running the command.

  See `Stdio.setuid/0`.

  ### sysctl(8)

  [sysctl(8)](https://www.freebsd.org/cgi/man.cgi?sysctl(8)) settings
  control the behaviour of the jail. For example, to allow ping/traceroute
  from the jail:

      sysctl security.jail.allow_raw_sockets=1

  See [jail(8)](https://www.freebsd.org/cgi/man.cgi?jail(8)).

  ## Operations

  See `t:Stdio.config/0` for configuration options.

  * creates a new session

  * sets the process priority [:priority=0]

  * puts the process into a `jail(2)`

  * sets resource limits [:rlimit=coredumps disabled]

  * sets additional groups [:groups=additional groups removed]

  * drops privileges to the value of `uid` and `gid` or a high UID system
    user [:uid/:gid=65536-131071]

  * disables the capability to elevate privileges [:setuid=false]

  > #### Warning {: .warning}
  > The generated UID/GID may overlap with existing users.

  ## Examples

      iex> Stdio.stream!(["./echo", "test"], Stdio.Jail, path: "/rescue")
      ...> |> Enum.to_list()
      [stdout: "test\n", exit_status: 0]

      iex> Stdio.stream!(
      ...> ["sh", "-c", "export PATH=/; ping -c 1 127.0.0.1 | head -1"],
      ...> Stdio.Jail,
      ...> uid: 0, path: "/rescue", setuid: true, net: :host
      ...>) |> Enum.to_list()
      [stdout: "PING 127.0.0.1 (127.0.0.1): 56 data bytes\n", exit_status: 0]

  """

  @impl true
  def task(_config) do
    Stdio.supervisor(:noreap)
  end

  @impl true
  def ops(config) do
    net =
      case Keyword.get(config, :net, :none) do
        :none ->
          %{ip4: [], ip6: []}

        :host ->
          {:ok, [{_ifname, flags} | _]} = :inet.getifaddrs()

          ip4 =
            for {_, _, _, _} = ip <-
                  Keyword.get_values(flags, :addr),
                do: ip

          ip6 =
            for {_, _, _, _, _, _, _, _} = ip <-
                  Keyword.get_values(flags, :addr),
                do: ip

          %{ip4: ip4, ip6: ip6}

        inet when is_map(inet) ->
          inet
      end

    uid = Keyword.get(config, :uid, :erlang.phash2(self(), 0xFFFF) + 0x10000)
    gid = Keyword.get(config, :gid, uid)
    groups = Keyword.get(config, :groups, [])

    priv_dir = Stdio.__basedir__()

    path =
      Keyword.get(
        config,
        :path,
        Path.join(
          priv_dir,
          "root"
        )
      )

    hostname = Keyword.get(config, :hostname, "stdio#{uid}")

    jail =
      __cstruct__(%{
        path: path,
        hostname: hostname,
        jailname: hostname,
        ip4: Map.get(net, :ip4, []),
        ip6: Map.get(net, :ip6, [])
      })

    [
      {:setsid, []},
      {:setpriority, [:prio_process, 0, Keyword.get(config, :priority, 0)]},
      {:jail, [jail]},
      {:chdir, ["/"]},
      for {resource, rlim} <-
            Keyword.get(config, :rlimit, [
              {:rlimit_core, %{cur: 0, max: 0}}
            ]) do
        {:setrlimit, [resource, rlim]}
      end,
      {:setgroups, [groups]},
      {:setresgid, [gid, gid, gid]},
      {:setresuid, [uid, uid, uid]},
      if Keyword.get(config, :setuid, false) do
        []
      else
        Stdio.Syscall.os().disable_setuid()
      end
    ]
  end

  defp aton(ips) do
    ips
    |> Enum.flat_map(fn
      ipstr when is_binary(ipstr) ->
        case :inet.parse_address(String.to_charlist(ipstr)) do
          {:ok, ip} -> [ip]
          {:error, _} -> []
        end

      ip when is_tuple(ip) ->
        [ip]
    end)
  end

  defp pad(n), do: :alcove.wordalign(n) * 8

  # Create the jail(2) C struct
  #
  # :prx will construct the C struct from the map:
  #
  #     :prx.jail(task, opt)
  #
  # But to make debugging simpler from elixir, provide a version of the
  # cstruct conversion which can be called from iex.
  def __cstruct__(opt) do
    addr4 = aton(Map.get(opt, :ip4, []))
    addr6 = aton(Map.get(opt, :ip6, []))

    ip4 =
      for {ip1, ip2, ip3, ip4} <- addr4 do
        <<ip1, ip2, ip3, ip4>>
      end

    ip6 =
      for {ip1, ip2, ip3, ip4, ip5, ip6, ip7, ip8} <- addr6 do
        <<ip1::16, ip2::16, ip3::16, ip4::16, ip5::16, ip6::16, ip7::16, ip8::16>>
      end

    pad = pad(4)

    [
      <<2::32-native>>,
      <<0::size(pad)>>,
      {:ptr, <<"#{opt.path}", 0>>},
      {:ptr, <<"#{opt.hostname}", 0>>},
      {:ptr, <<"#{opt.jailname}", 0>>},
      <<length(opt.ip4)::32-native>>,
      <<length(opt.ip6)::32-native>>,
      {:ptr, :binary.list_to_bin(ip4)},
      {:ptr, :binary.list_to_bin(ip6)}
    ]
  end
end
