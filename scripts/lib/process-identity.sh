# Process identity for the acceptance scripts' cleanup (sourced, POSIX sh).
#
# A pid is reused once its process exits, so a script signals a pid it started
# only while that pid still has the identity recorded at launch: the start
# time and the executable, both as `ps` reports them. Otherwise it leaves the
# process alone and says so.

# The identity of pid $1: "<start time> <executable>", or nothing if it is gone.
proc_identity() {
    [ -n "$1" ] || return 1
    ps -o lstart= -o comm= -p "$1" 2>/dev/null
}

# Print the identity of pid $1 once it runs executable $2 (as it was started).
# Right after `cmd &` the pid may still be the shell about to exec, so this
# waits up to about 5 s; it fails at once if the pid is gone.
proc_record() {
    _pr_i=0
    while [ "$_pr_i" -lt 50 ]; do
        _pr_id=$(proc_identity "$1") || return 1
        case "$_pr_id" in *" $2") printf '%s\n' "$_pr_id"; return 0 ;; esac
        sleep 0.1; _pr_i=$((_pr_i + 1))
    done
    return 1
}

# Whether pid $1 still has identity $2.
proc_same() { [ -n "$1" ] && [ -n "$2" ] && [ "$(proc_identity "$1")" = "$2" ]; }

# Stop pid $1 only while it has identity $2, and wait up to 10 s for it to go.
# Succeeds when the process with that identity is no longer running; a pid
# that now belongs to another process is never signalled.
proc_stop() {
    proc_same "$1" "$2" || return 0
    kill "$1" 2>/dev/null
    _ps_i=0
    while proc_same "$1" "$2" && [ "$_ps_i" -lt 20 ]; do sleep 0.5; _ps_i=$((_ps_i + 1)); done
    ! proc_same "$1" "$2"
}

# Explain a recorded pid that was not stopped: gone already, reused, or never
# identified. Prints nothing when the recorded process simply exited.
proc_left() { # pid identity name
    if [ -z "$2" ]; then
        kill -0 "$1" 2>/dev/null && echo "CLEANUP: $3 (pid $1) was started but its identity was not recorded, so it was not stopped; quit it by hand"
    elif proc_same "$1" "$2"; then
        echo "CLEANUP: $3 (pid $1) is still running after the stop request; quit it by hand"
    elif [ -n "$(proc_identity "$1")" ]; then
        echo "CLEANUP: pid $1 now belongs to another process ($(proc_identity "$1")), not $3; it was left alone"
    fi
    return 0
}
