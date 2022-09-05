%% @doc Create and enforce seccomp(2) filters
-module(seccomp).

-include_lib("alcove/include/alcove_seccomp.hrl").

-export([
    deny/2
]).

-type filter() ::
    {deny, prx:constant() | integer()}
    | {deny, prx:constant() | integer(), atom() | integer()}.

-export_type([
    filter/0
]).

-define(DENY_SYSCALL(Syscall), [
    ?BPF_JUMP(?BPF_JMP + ?BPF_JEQ + ?BPF_K, (Syscall), 0, 1),
    ?BPF_STMT(?BPF_RET + ?BPF_K, ?SECCOMP_RET_KILL)
]).

-define(DENY_SYSCALL(Syscall, Errno), [
    ?BPF_JUMP(?BPF_JMP + ?BPF_JEQ + ?BPF_K, (Syscall), 0, 1),
    ?BPF_STMT(?BPF_RET + ?BPF_K, ?SECCOMP_RET_ERRNO bor Errno)
]).

errno('EPERM') -> 1;
errno('ENOENT') -> 2;
errno('ESRCH') -> 3;
errno('EINTR') -> 4;
errno('EIO') -> 5;
errno('ENXIO') -> 6;
errno('E2BIG') -> 7;
errno('ENOEXEC') -> 8;
errno('EBADF') -> 9;
errno('ECHILD') -> 10;
errno('EAGAIN') -> 11;
errno('ENOMEM') -> 12;
errno('EACCES') -> 13;
errno('EFAULT') -> 14;
errno('ENOTBLK') -> 15;
errno('EBUSY') -> 16;
errno('EEXIST') -> 17;
errno('EXDEV') -> 18;
errno('ENODEV') -> 19;
errno('ENOTDIR') -> 20;
errno('EISDIR') -> 21;
errno('EINVAL') -> 22;
errno('ENFILE') -> 23;
errno('EMFILE') -> 24;
errno('ENOTTY') -> 25;
errno('ETXTBSY') -> 26;
errno('EFBIG') -> 27;
errno('ENOSPC') -> 28;
errno('ESPIPE') -> 29;
errno('EROFS') -> 30;
errno('EMLINK') -> 31;
errno('EPIPE') -> 32;
errno('EDOM') -> 33;
errno('ERANGE') -> 34;
errno('ENOSYS') -> 38;
errno(Errno) when is_integer(Errno) -> Errno.

filter(Task, Syscalls) ->
    Arch = prx:call(Task, syscall_constant, [alcove:audit_arch()]),
    [
        ?VALIDATE_ARCHITECTURE(Arch),
        ?EXAMINE_SYSCALL
        | insn(Task, Syscalls)
    ].

syscall(Task, Syscall) ->
    prx:call(Task, syscall_constant, [Syscall]).

insn(Task, Syscalls) ->
    insn(Task, Syscalls, []).

insn(_Task, [], Prog) ->
    lists:reverse(Prog);
insn(Task, [{deny, Syscall} | Syscalls], Prog) ->
    case syscall(Task, Syscall) of
        unknown ->
            [];
        NR ->
            insn(Task, Syscalls, [
                [
                    ?DENY_SYSCALL(NR),
                    ?BPF_STMT(?BPF_RET + ?BPF_K, ?SECCOMP_RET_ALLOW)
                ]
                | Prog
            ])
    end;
insn(Task, [{deny, Syscall, Errno} | Syscalls], Prog) ->
    case syscall(Task, Syscall) of
        unknown ->
            [];
        NR ->
            insn(Task, Syscalls, [
                [
                    ?DENY_SYSCALL(NR, errno(Errno)),
                    ?BPF_STMT(?BPF_RET + ?BPF_K, ?SECCOMP_RET_ALLOW)
                ]
                | Prog
            ])
    end.

%% @doc Operations to deny syscalls for a process using a seccomp(2) filter
%%
%% Creates a BPF program that will deny the provided syscalls, returning
%% the seccomp operations to enforce the filter using `Stdio.Op.task!/4`.
%%
%% Syscalls can be denied (in which case the process will be terminated
%% with SIGSYS) or configured to return an errno value.
%%
%% Warning: the caller should disable new privileges before enforcing
%% the filter.
%%
%% == Examples ==
%%
%% ```
%% def disable_net() do
%%   [
%%     Stdio.Syscall.Linux.disable_setuid(),
%%     {:seccomp, :deny,
%%      [
%%        [
%%          {:sys_socket, :EACCES},
%%          {:sys_socketcall, :ENOSYS}
%%        ]
%%      ]}
%%   ]
%% end
%% '''
-spec deny(prx:task(), [filter()]) -> nonempty_list().
deny(Task, Syscalls) ->
    Filter = filter(Task, Syscalls),

    Pad = (erlang:system_info({wordsize, external}) - 2) * 8,

    Prog = [
        <<(iolist_size(Filter) div 8):2/native-unsigned-integer-unit:8>>,
        <<0:Pad>>,
        {ptr, list_to_binary(Filter)}
    ],
    [
        {prx, seccomp, [seccomp_set_mode_filter, 0, Prog]}
    ].
