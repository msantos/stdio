defmodule Stdio do
  defstruct init: :noproc, atexit: :shutdown, state: %{}

  @type pipeline :: [%{task: :prx.task(), pid: :prx.pid_t()}]

  @type t :: %__MODULE__{
          init: :prx.task() | :noproc,
          atexit:
            :shutdown
            | :noshutdown
            | :noreap
            | (init :: :prx.task(), pipeline :: pipeline, map() ->
                 any),
          state: map()
        }

  defmodule ProcessTree do
    @moduledoc ~S"""
    System process supervisor tree.
    """
    defstruct supervisor: %Stdio{}, pipeline: []

    @type t :: %__MODULE__{
            supervisor: Stdio.t(),
            pipeline: Stdio.pipeline()
          }

    def task(task) do
      case :prx.pidof(task) do
        :noproc ->
          raise Stdio.OpError,
            reason: :badinit,
            op: {Stdio, :init, []},
            error: :einval

        pid ->
          %{task: task, pid: pid}
      end
    end
  end

  @moduledoc ~S"""
  Stream standard I/O from system processes.

  ## Overview

  `Stdio` manages system processes. The process standard output (`stdout`)
  and standard error (`stderr`) are represented as `Stream`s of
  `t:stdio/0` tuples. `pipe!/4` reads standard input (`stdin`) from a
  binary stream.

  * system processes run as [foreground
    processes](https://jdebp.uk/FGA/unix-daemon-design-mistakes-to-avoid.html)
  * when the foreground process exits, daemonized and background
    subprocesses are reliably terminated
  * system processes are optionally restricted using behaviours such as
    `Stdio.Container`, `Stdio.Rootless` or `Stdio.Jail`

  ## Streaming stdout/stderr

  A simple example of creating a stream using `Stdio.stream!/1`:

      iex> Stdio.stream!("echo hello; echo world >&2") |> Enum.to_list()
      [stdout: "hello\n", stderr: "world\n", exit_status: 0]

  ## Piping to stdin

  An example of using a system process to transform a stream using
  `Stdio.pipe!/2`:

      iex> ["hello\n"] |> Stdio.pipe!("sed -u 's/hello/bye/'") |> Enum.to_list()
      [stdout: "bye\n", exit_status: 0]

  > #### Note {: .info}
  > Process output may be buffered. The pipe example
  > unbuffers the output by using the `-u` option of
  > [sed(1)](https://man7.org/linux/man-pages/man1/sed.1.html).

  ## Privileges

  > #### Warning {: .warning}
  > Some behaviours, notably `Stdio.Container` and `Stdio.Jail`,
  > require the system supervisor (not the beam process!) to be running as
  > the `root` user. See `setuid/0` for instructions for set up.

  Behaviours may change the root filesystem for the process. The default
  `chroot(2)` directory hierarchy can be created by running:

      iex> Stdio.Container.make_chroot_tree!()
      :ok

  ## Process Capabilities and Namespaces

  `Stdio` behaviours can restrict system process capabilities or isolate
  the process using namespaces or jails.

  The default implementation uses the standard `fork(2)`'ing process model.

  Other implementations are `Stdio.Container` (Linux
  [namespaces(7)](https://man7.org/linux/man-pages/man7/namespaces.7.html)),
  `Stdio.Rootless` (Linux
  [user_namespaces(7)](https://man7.org/linux/man-pages/man7/user_namespaces.7.html))
  and `Stdio.Jail` (FreeBSD [jail(2)](https://www.freebsd.org/cgi/man.cgi?jail(2))

      iex> Stdio.stream!("id -u", Stdio.Rootless) |> Enum.to_list()
      [stdout: "65534\n", exit_status: 0]

  ## Supervising System Processes

  `Stdio` processes can be supervised and restarted by a `Task.Supervisor`:

      Supervisor.start_link(
        [{Task.Supervisor, name: Init.TaskSupervisor}],
        strategy: :one_for_one
      )

   To create and supervise a system process:

      require Logger

      Task.Supervisor.start_child(
        Init.TaskSupervisor,
        fn ->
          Stdio.stream!("nc -l 4545")
          |> Stream.each(fn
            {:stdout, e} ->
              Logger.info(e)

            {:stderr, e} ->
              Logger.error(e)

            e ->
              Logger.warn("#{inspect(e)}")
          end)
          |> Stream.run()
        end,
        restart: :permanent
      )

  In another shell, connect to port 4545 and send some data:

      $ nc localhost 4545
      test
      123
      ^C

      $ nc localhost 4545
      netcat was restarted by the supervisor!
      ^C

  In `iex`:

      05:40:26.277 [info]  test
      05:40:27.669 [info]  123
      05:40:28.044 [warning] {:exit_status, 0}
      05:40:52.929 [info]  netcat was restarted by the supervisor!
      05:40:53.451 [warning] {:exit_status, 0}

  """

  @doc """
  Function to create a system supervisor for the `Stdio` stream.

  Create a task using `:prx.fork/0` and configured as a process
  supervisor.

  See `supervise/1` for the default operations.
  """
  @callback task(Keyword.t()) :: {:ok, Stdio.t()} | {:error, atom}

  @doc """
  Function to `fork(2)` a system subprocess from the supervisor created
  by the `c:task/1` callback.

  In a PID namespace, this process will be the `init` process or PID 1.
  """
  @callback init(Keyword.t()) ::
              (:prx.task() -> {:ok, pipeline} | {:error, :prx.posix()})

  @doc """
  Function run on operation error.

  `c:onerror/1` runs if any of the operations defined in `c:ops/1`
  returns an error. An error is an error tuple:

      {:error, :prx.posix()}

  The return value of `c:onerror/1` is ignored. Exceptions within the
  callback are not handled by default and may terminate the linked
  process.

  The supervisor process for the task can be found by calling
  `:prx.parent/1`. For example, to signal the process group:

      supervisor = :prx.parent(sh)
      :prx.kill(supervisor, 0, :SIGTERM)

  """
  @callback onerror(Keyword.t()) :: (sh :: :prx.task() -> any)

  @doc """
  A sequence of `t:Stdio.Op.t()/0` instructions for a system process.

  Operations are defined in [prx](https://hexdocs.pm/prx/prx.html)
  but any module can be called by specifying the module name.
  """
  @callback ops(Keyword.t()) :: [Stdio.Op.t()]

  @doc """
  Function run during stream termination.

  `c:onexit/1` runs when the stream is closed. The function can perform
  clean up and signal any lingering processes. Returns `true` if
  subprocesses were found to be running during cleanup.
  """
  @callback onexit(Keyword.t()) :: (Stdio.ProcessTree.t() -> boolean())

  @environ [
    ~s(PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin:/opt/sbin:/opt/bin),
    ~s(HOME=/home)
  ]

  @typedoc """
  Phases are functions defining how a process is forked, configured
  and supervised.

  Phases can be implemented as a behaviour or as a list of functions.

  ```mermaid
  stateDiagram-v2
      direction LR
      [*] --> Supervisor: fork(2)
      Supervisor --> Subprocess: fork(2)
      Subprocess --> Terminate: stream
      Terminate --> [*]
      state Supervisor {
          direction LR
          [*] --> task
          task --> [*]
      }
      state Subprocess {
          state result <<choice>>
          direction LR
          [*] --> init
          init --> ops
          ops --> result
          result --> [*]: ok
          result --> onerror: {error, posix()}
      }
      state Terminate {
          direction LR
          onexit --> [*]
      }
  ```

  ## task

  Returns a `t::prx.task/0` system process configured to act as a system
  process supervisor.

  ## init

  Forks and initializes a subprocess of the system process
  supervisor. When using namespaces, this process will be PID 1 or the
  container `init` process.

  ## ops

  Provides a sequence of system calls to run on the subprocess.

  ## onerror

  Function called to clean up if any of the operations defined in
  `c:ops/1` fail.

  ## onexit

  Function called when the stream is closed.
  """
  @type phase ::
          {:task, (Keyword.t() -> {:ok, Stdio.t()} | {:error, :prx.posix()})}
          | {:init,
             (Keyword.t() ->
                (init :: :prx.task() ->
                   {:ok, pipeline :: pipeline}
                   | {:error, :prx.posix()}))}
          | {:ops, (Keyword.t() -> [Stdio.Op.t()])}
          | {:onerror, (Keyword.t() -> (sh :: :prx.task() -> any))}
          | {:onexit, (Keyword.t() -> (Stdio.ProcessTree.t() -> boolean()))}

  @typedoc ~S"""
  Configuration options for callbacks:

  ## net

  Defines the network capability for behaviours with support for network
  namespaces.

  * none: process does not have access to network
  * host: process shares the host's network namespace

  ## environ

  Set the process environment using a list of `=` separated strings.

      iex> Stdio.stream!(["/usr/bin/env"], Stdio.Process, environ: ["TERM=dumb", "PATH=/bin"]) |> Enum.to_list()
      [stdout: "TERM=dumb\nPATH=/bin\n", exit_status: 0]

  ## uid

  > **Requires `setuid/0`**

  Set the UID of the subprocess. If not set, a UID is generated by
  the behaviour.

  ## gid

  > **Requires `setuid/0`**

  Set the GID of the subprocess. If not set, a GID is generated by
  the behaviour.

  ## groups

  > **Requires `setuid/0`**

  Set a list of additional groups (a list of GIDs) for the subprocess. By
  default, additional groups are dropped.

  ## fstab

  > **Requires `setuid/0`**

  A list of directories to bind mount inside of the container
  namespace. Relative paths are resolved relative to the application
  `priv` directory.

  ## path

  > **May require `setuid/0`**

  Sets the working directory of the subprocess. Behaviours changing the
  root directory use `path` as the root.

  ## hostname

  > **Requires `setuid/0`**

  Sets the hostname of the process.

  ## setuid

  If set to `false` (the default), drops privileges before running
  the command.

  ## priority

  Sets the process priority (default: 0).

  ## rlimit

  A map containing `setrlimit(2)` settings. The default disables core dumps.
  """
  @type config ::
          {:net, :none | :host}
          | {:environ, [String.t()]}
          | {:uid, non_neg_integer}
          | {:gid, non_neg_integer}
          | {:groups, [non_neg_integer]}
          | {:fstab, [String.t()]}
          | {:path, Path.t()}
          | {:hostname, String.t()}
          | {:setuid, boolean}
          | {:priority, -20..19}
          | {:rlimit,
             {:rlimit_core
              | :rlimit_cpu
              | :rlimit_fsize
              | :rlimit_nofile
              | :rlimit_nproc, %{cur: integer, max: integer}}}
          | {Keyword.key(), Keyword.value()}

  @typedoc """
  Tuples containing the process stdout, stderr and termination status.
  * `:stdout`: standard output
  * `:stderr`: standard error
  * `:exit_status`: process has exited with status value
  * `:termsig`: the termination signal if the process exited due to a signal
  """
  @type stdio ::
          {:stdout, binary} | {:stderr, binary} | {:exit_status, integer} | {:termsig, atom}

  @doc false
  defmacro __using__(_) do
    quote location: :keep do
      @behaviour Stdio

      @doc false
      def task(config) do
        Stdio.Process.task(config)
      end

      @doc false
      def init(config) do
        Stdio.Process.init(config)
      end

      @doc false
      def onerror(config) do
        Stdio.Process.onerror(config)
      end

      @doc false
      def ops(config) do
        Stdio.Process.ops(config)
      end

      @doc false
      def onexit(config) do
        Stdio.Process.onexit(config)
      end

      defoverridable task: 1, init: 1, onerror: 1, ops: 1, onexit: 1
    end
  end

  @doc ~S"""
  Stream standard I/O from system processes.

  ## command

  Commands are strings interpreted by `/bin/sh` or list of strings
  (an argv) passed directly to `execve(2)`.

  > #### Warning {: .warning}
  > When using an argv, $PATH is not consulted. The path to the
  > executable must be provided as the first argument.

  ## behaviour

  The process behaviour can be customized by passing in:
  * a module implementing the callbacks
  *  a keyword list with functions of type `t:phase/0`
  * a tuple consisting of a module and a list of `t:phase/0` functions
    to override the module callbacks

  ## config

  For configuration options, see `t:config/0`.

  ## Examples

      iex> Stdio.stream!("echo test") |> Enum.to_list()
      [stdout: "test\n", exit_status: 0]

      iex> Stdio.stream!(["/bin/echo", "test"]) |> Enum.to_list()
      [stdout: "test\n", exit_status: 0]

      iex> Stdio.stream!("ip --oneline -4 addr show dev lo", Stdio.Container) |> Enum.to_list()
      [exit_status: 0]

      iex> Stdio.stream!("ip --oneline -4 addr show dev lo", Stdio.Container, net: :host) |> Enum.to_list()
      [
          stdout: "1: lo    inet 127.0.0.1/8 scope host lo\\       valid_lft forever preferred_lft forever\n",
          exit_status: 0
      ]

      iex> Stdio.stream!("pwd", {Stdio.Process, ops: fn _ -> [{:chdir, ["/tmp"]}] end}) |> Enum.to_list()
      [stdout: "/tmp\n", exit_status: 0]

  """
  @spec stream!(
          String.t()
          | [String.t(), ...]
          | {arg0 :: String.t(), argv :: [String.t(), ...]},
          module | [phase] | {module, [phase]},
          task: [config],
          init: [config],
          ops: [config],
          onexit: [config],
          onerror: [config]
        ) :: Enumerable.t()
  def stream!(command, behaviour \\ Stdio.Process, config \\ []) do
    fun = implementation(behaviour)
    taskfun = Keyword.get(fun, :task, &Stdio.Process.task/1)
    initfun = Keyword.get(fun, :init, &Stdio.Process.init/1)
    opsfun = Keyword.get(fun, :ops, &Stdio.Process.ops/1)
    onerrorfun = Keyword.get(fun, :onerror, &Stdio.Process.onerror/1)
    onexitfun = Keyword.get(fun, :onexit, &Stdio.Process.onexit/1)

    Stdio.Stream.__stream__(
      command,
      config,
      opsfun,
      initfun,
      onerrorfun,
      taskfun,
      onexitfun
    )
  end

  @doc ~S"""
  Pipe data into the standard input of a system process.

  Input is a stream of binaries. Empty binaries are ignored.

  See `stream!/3` for arguments.

  ## Examples

      iex> Stream.unfold(1000, fn 0 -> nil; n -> {"#{n}\n", n - 1} end)
      ...> |> Stdio.pipe!("grep --line-buffered 442")
      ...> |> Enum.to_list()
      [stdout: "442\n", exit_status: 0]

      iex> Stdio.stream!("echo test; kill $$")
      iex> |> Stream.transform(<<>>, &Stdio.Stream.stdout_to_stderr/2)
      iex> |> Stdio.pipe!("sed -u 's/t/_/g'")
      iex> |> Enum.to_list()
      [stdout: "_es_\n", exit_status: 0]

      iex> [<<>>, <<"a">>, <<>>] |> Stdio.pipe!("cat") |> Enum.to_list()
      [stdout: "a", exit_status: 0]

  """
  @spec pipe!(
          Enumerable.t(),
          String.t()
          | [String.t(), ...]
          | {arg0 :: String.t(), argv :: [String.t(), ...]},
          module | [phase] | {module, [phase]},
          task: [config],
          init: [config],
          ops: [config],
          onerror: [config],
          onexit: [config]
        ) :: Enumerable.t()

  def pipe!(stream, command, behaviour \\ Stdio.Process, config \\ []) do
    fun = implementation(behaviour)
    opsfun = Keyword.get(fun, :ops, &Stdio.Process.ops/1)
    initfun = Keyword.get(fun, :init, &Stdio.Process.init/1)
    onerrorfun = Keyword.get(fun, :onerror, &Stdio.Process.onerror/1)
    taskfun = Keyword.get(fun, :task, &Stdio.Process.task/1)
    onexitfun = Keyword.get(fun, :onexit, &Stdio.Process.onexit/1)

    Stdio.Stream.__pipe__(
      stream,
      command,
      config,
      opsfun,
      initfun,
      onerrorfun,
      taskfun,
      onexitfun
    )
  end

  @spec setuid?() :: boolean
  defp setuid?() do
    stat = File.stat!(:prx_drv.progname())
    Bitwise.band(stat.mode, 0o4000) != 0
  end

  @doc """
  Request system supervisor runs as root.

  Some system calls require the process to be UID 0. These calls typically
  are operations like mounting filesystems or creating new namespaces
  (excluding user namespaces such as `Stdio.Rootless`) or putting a
  process into a `jail(2)` or a `chroot(2)`.

  > ### Warning {: .warning}
  > Enabling privileges is a global setting: all system supervisor
  > processes will run as UID 0.

  ## Setuid Binary

  Probably the simplest method for production use is adding the setuid
  bit to the `prx` binary (see `:prx_drv.progname/0`):

  * create a group with privileges to run the supervisor (optional)

      	# example: create an elixir group
      	groupadd elixir

  * find the location of the binary

      	:prx_drv.progname()

  * set the setuid bit

      	sudo chown root:elixir /path/to/priv/prx
      	sudo chmod 4750 /path/to/priv/prx

  ## Using a Setuid Exec Chain

  `prx` can be configured to use a setuid helper program such as `sudo(8)`
  or `doas(1)`.

  `Stdio.setuid/0` is a noop if the `prx` binary is setuid.

  Before launching any supervisors, run:

       Stdio.setuid()

  ### sudo(8)

  		$ sudo visudo
  		elixiruser ALL = NOPASSWD: /path/to/prx/priv/prx
  		Defaults!/path/to/prx/priv/prx !requiretty

  ### doas(8)

  		permit nopass setenv { ENV PS1 SSH_AUTH_SOCK } :elixirgroup

  ### Errors

  #### `shell process exited with reason: {:error, {:error, :eagain}}`

  Check `prx` is executable:

  ```
  $ ./deps/prx/priv/prx -h
  prx 0.40.5
  usage: prx -c <path> [<options>]
  ```

  #### `error attempting to fork subprocess: insufficient permissions (eperm)`

  Verify `prx` can be run using `sudo`:

  ```
  $ sudo ./deps/prx/priv/prx -h
  prx 0.40.5
  usage: prx -c <path> [<options>]
  ```
  """
  def setuid(), do: __setuid__(true)

  # Sets an application environment variable.
  #
  # Globally enables or disables setuid privileges: probably only useful
  # when testing.
  def __setuid__(false), do: :prx.sudo("")

  def __setuid__(true) do
    case setuid?() do
      false ->
        exec =
          case :os.type() do
            {:unix, :openbsd} -> "doas"
            _ -> "sudo -n"
          end

        :prx.sudo(exec)

      true ->
        :ok
    end
  end

  @spec __fork__(
          t,
          String.t()
          | [String.t(), ...]
          | {arg0 :: String.t(), argv :: [String.t(), ...]},
          [config],
          opsfun :: (Keyword.t() -> [Stdio.Op.t()]),
          initfun ::
            (Keyword.t() ->
               (init :: :prx.task() ->
                  {:ok, pipeline :: pipeline}
                  | {:error, :prx.posix()})),
          onerrorfun :: (Keyword.t() -> (sh :: :prx.task() -> any))
        ) :: {:ok, Stdio.ProcessTree.t()} | {:error, :prx.posix()}
  def __fork__(%Stdio{} = supervisor, command, config, opsfun, initfun, onerrorfun) do
    environ = Keyword.get(config, :environ, @environ)

    fstab =
      Keyword.get(config, :fstab, [])
      |> Enum.reject(fn t -> t == "" end)

    config = Keyword.merge(config, fstab: fstab)

    pipeline =
      Stdio.Op.task!(
        supervisor,
        opsfun.(config),
        initfun.(config),
        onerrorfun.(config)
      )

    sh = List.last(pipeline).task
    {arg0, argv} = argv(command)

    errno =
      try do
        :prx.execve(sh, arg0, argv, environ)
      rescue
        _ ->
          {:error, :enoent}
      end

    case errno do
      :ok ->
        {:ok,
         %Stdio.ProcessTree{
           supervisor: supervisor,
           pipeline: pipeline
         }}

      {:error, _} = error ->
        :prx.stop(sh)
        error
    end
  end

  defp argv(command) when is_binary(command), do: {"/bin/sh", ["/bin/sh", "-c", command]}
  defp argv(command) when is_list(command), do: {List.first(command, ""), command}
  defp argv({arg0, argv} = command) when is_binary(arg0) and is_list(argv), do: command

  def __atexit__(%Stdio.ProcessTree{supervisor: %Stdio{init: init, atexit: :noshutdown}}) do
    flush(init)
  end

  def __atexit__(%Stdio.ProcessTree{supervisor: %Stdio{init: init, atexit: :noreap}}) do
    :prx.stop(init)
    flush(init)
  end

  def __atexit__(
        %Stdio.ProcessTree{
          supervisor: %Stdio{init: init, atexit: :shutdown}
        } = pstree
      ) do
    reap(pstree, :SIGKILL)
    :prx.stop(init)
    flush(init)
  end

  def __atexit__(%Stdio.ProcessTree{
        supervisor: %Stdio{init: init, atexit: atexit, state: state},
        pipeline: pipeline
      })
      when is_function(atexit, 3) do
    atexit.(init, pipeline, state)
    flush(init)
  end

  # Stream has exited: any messages remaining in the process mailbox
  # will not be read.
  defp flush(task) do
    receive do
      {:signal, _task, _, _} ->
        flush(task)

      # Flush any remaining events:
      #
      # * pipeline may not consume entire stream (`Enum.take/2`)
      # * subprocess may have exited (e.g., due to EPERM) during stream
      #   initialization
      {:stdout, _, _} ->
        flush(task)

      {:stderr, _, _} ->
        flush(task)

      {:termsig, _, _} ->
        flush(task)

      {:exit_status, _, _} ->
        flush(task)
    after
      0 ->
        :ok
    end
  end

  @doc ~S"""
  Terminate descendents of a supervisor process.
  """
  @spec reap(Stdio.ProcessTree.t(), atom) :: :ok
  def reap(%Stdio.ProcessTree{} = pstree, signal \\ :SIGKILL) do
    _ = Stdio.Syscall.os().reap(pstree, signal)
    :ok
  end

  @doc ~S"""
  Terminate descendents of a process.

  reap signals subprocesses of a process identified by PID.

  Background and daemonized subprocesses will also be terminated if
  supported by the platform.
  """
  @spec reap(Stdio.ProcessTree.t(), :prx.pid_t(), atom) :: :ok
  def reap(%Stdio.ProcessTree{} = pstree, pid, signal) do
    _ = Stdio.Syscall.os().reap(pstree, pid, signal)
    :ok
  end

  @allowed_calls {:allow,
   [
     :close,
     :exit,
     :fork,
     :getpid,
     :kill,
     :setcpid,
     :sigaction,

     # Linux
     :clone,

     # FreeBSD
     :procctl
   ]}

  @doc """
  Create a supervisor task

  Returns a `t:Stdio.t/0` configured to act as a system process supervisor.
  """
  @spec supervisor(
          :shutdown
          | :noshutdown
          | :noreap
          | (init :: :prx.task(), pipeline :: pipeline, state :: map() ->
               any),
          [:prx.call()] | {:allow, [:prx.call()]} | {:deny, [:prx.call()]}
        ) :: {:ok, Stdio.t()} | {:error, :prx.posix()}
  def supervisor(atexit \\ :shutdown, filter \\ @allowed_calls) do
    case :prx.fork() do
      {:ok, init} ->
        case supervise(init, atexit, filter) do
          {:ok, _} = t ->
            t

          {:error, _} = error ->
            :prx.stop(init)
            error
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Configure a task to be a system process supervisor.

  The task:
  * becomes an init process (dependent on platform)
  * sets the process name to `supervise`
  * enables flow control for child stdout/stderr
  * sets the shutdown/reaper behaviour
  * terminates child processes if beam exits
  * restricts the task to a limited set of calls required for supervision
  """
  @spec supervise(
          :prx.task(),
          :shutdown
          | :noshutdown
          | :noreap
          | (init :: :prx.task(), pipeline :: pipeline, state :: map() ->
               any),
          [:prx.call()] | {:allow, [:prx.call()]} | {:deny, [:prx.call()]}
        ) :: {:ok, Stdio.t()} | {:error, :prx.posix()}
  def supervise(init, atexit \\ :shutdown, filter \\ @allowed_calls) do
    with :ok <- Stdio.Syscall.os().subreaper(init),
         {:ok, _} <- :prx.sigaction(init, :sigpipe, :sig_ign),
         {:ok, _} <- :prx.sigaction(init, :sigill, :sig_dfl),
         {:ok, _} <- :prx.sigaction(init, :sigbus, :sig_dfl),
         {:ok, _} <- :prx.sigaction(init, :sigsegv, :sig_dfl),
         :ok <- Stdio.Syscall.os().setproctitle(init, "Supervise") do
      _ = :prx.setopt(init, :signaloneof, 9)
      _ = :prx.setopt(init, :flowcontrol, 1)
      :ok = :prx.filter(init, filter, [])
      {:ok, %Stdio{init: init, atexit: atexit}}
    end
  end

  @doc ~S"""
  Use a previously created supervisor process.

  The supervisor is not shutdown when the stream exits.

  ## Examples

      iex> {:ok, supervisor} = Stdio.supervisor(:noshutdown)
      iex> Stdio.stream!("echo test", Stdio.with_supervisor(Stdio.Process, supervisor)) |> Enum.to_list()
      [stdout: "test\n", exit_status: 0]
      iex> Stdio.stream!("echo test", Stdio.with_supervisor(Stdio.Process, supervisor)) |> Enum.to_list()
      [stdout: "test\n", exit_status: 0]
      iex> :prx.stop(supervisor.init)

  ```mermaid
  graph LR
      B([beam]) --> S[Supervise]
      S -.-> I0[[sh]]
      S --> I1[[sh]]
      I0 -.-> C0[[echo test]]
      I1 --> C1[[echo test]]
  ```
  """
  @spec with_supervisor(module, Stdio.t()) :: Keyword.t()
  def with_supervisor(module, %Stdio{} = supervisor) when is_atom(module),
    do:
      Keyword.merge(
        implementation(module),
        task: fn _config -> {:ok, supervisor} end
      )

  # Convert a module implementing the Stdio behaviour into a list
  # of functions with the process lifecycle callbacks.
  @spec implementation(module | [phase] | {module, [phase]}) :: Keyword.t()
  defp implementation(module) when is_atom(module),
    do: [
      ops: &module.ops/1,
      init: &module.init/1,
      onerror: &module.onerror/1,
      task: &module.task/1,
      onexit: &module.onexit/1
    ]

  defp implementation(funs) when is_list(funs), do: funs

  defp implementation({module, funs}) when is_atom(module) and is_list(funs) do
    Keyword.merge(
      [
        ops: &module.ops/1,
        init: &module.init/1,
        onerror: &module.onerror/1,
        task: &module.task/1,
        onexit: &module.onexit/1
      ],
      funs
    )
  end

  def __basedir__() do
    case :code.priv_dir(__MODULE__) do
      {:error, :bad_name} ->
        dir =
          case :code.which(__MODULE__) do
            path when is_atom(path) -> File.cwd!()
            path when is_list(path) -> path
          end

        Path.join([Path.dirname(dir), "..", "priv"])

      path ->
        path
    end
  end
end
