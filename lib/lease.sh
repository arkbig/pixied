#!/usr/bin/env bash
# @brief Runtime lease management for PixiEden.
# @description
# Represents the liveness of a running pixied CLI (shell or run) with a lease
# file instead of a long-held state lock. Multiple runtimes may coexist on the
# same machine, so a lease is not an exclusivity key: it only records that a
# given process is alive so install and uninstall can warn or refuse. Lease
# creation, scanning, stale removal, and ancestor exclusion live here and
# nowhere else.

if [ -n "${PIXIED_LEASE_LOADED:-}" ]; then
    # shellcheck disable=SC2317 # Sourced by both the source and deployed CLI.
    return 0 2>/dev/null || exit 0
fi
PIXIED_LEASE_LOADED=1

# Reset unconditionally: a child pixied CLI may inherit an exported
# PIXIED_LEASE_FILE from its parent runtime, but that lease belongs to the
# parent. Clearing it here keeps the child's own EXIT cleanup from deleting
# the parent runtime's lease file.
PIXIED_LEASE_FILE=""
# @active Alive lease entries as 'pid|comm|kind|args' lines after a sweep.
PIXIED_LEASE_ACTIVE_LIST=()
# @active Non-ancestor alive lease entries after pixied_lease_other_active.
PIXIED_LEASE_OTHER_LIST=()

# @brief Return the lease directory for the current installation.
# @description
# The lease directory mirrors the machine-local lock scoping so multiple
# machines sharing an account home keep independent leases. Local mode uses the
# state root; NFS mode uses the current machine state directory.
#
# @stdout The canonical lease directory path.
# @exitcode 0 When the required state path is available.
# @exitcode 1 When the state path cannot be determined.
pixied_lease_dir() {
    local state_dir=${PIXIED_STATE_DIR:-} machine_state_dir=${PIXIED_MACHINE_STATE_DIR:-}
    if [ "${PIXIED_HOME_MODE:-local}" = nfs ]; then
        if [ -z "$machine_state_dir" ] && [ -n "${PIXIED_MACHINE_ID:-}" ] && [ -n "$state_dir" ]; then
            machine_state_dir="$state_dir/machines/$PIXIED_MACHINE_ID"
        fi
        [ -n "$machine_state_dir" ] || pixied_die "machine state directory is not set"
        printf '%s/leases' "$machine_state_dir"
    else
        [ -n "$state_dir" ] || pixied_die "state directory is not set"
        printf '%s/leases' "$state_dir"
    fi
}

# @brief Read one value field from a lease record.
# @description
# Returns the value of the first 'key=value' line for the given key. An absent
# key yields empty output.
#
# @arg $1 string The lease file path.
# @arg $2 string The key to read (pid, comm, kind, or args).
# @stdout The field value, or empty when absent.
# @exitcode 0 Always.
pixied_lease_record_field() {
    local path=$1 key=$2
    [ -f "$path" ] || return 0
    sed -n "s/^${key}=//p" -- "$path" 2>/dev/null | head -n 1
}

# @brief Resolve the comm of a pid.
# @description
# Prefers /proc/<pid>/comm and falls back to 'ps -o comm='. Emits an empty
# string when neither source is readable so the caller can treat the process as
# not verifiable.
#
# @arg $1 integer The process id to inspect.
# @stdout The process comm, or empty when it cannot be determined.
# @exitcode 0 Always.
pixied_lease_proc_comm() {
    local pid=$1 comm=""
    [ -n "$pid" ] || return 0
    if [ -r "/proc/$pid/comm" ]; then
        comm=$(head -n 1 -- "/proc/$pid/comm" 2>/dev/null)
    fi
    if [ -z "$comm" ] && pixied_have_cmd ps; then
        comm=$(pixied_run ps -p "$pid" -o comm= 2>/dev/null | head -n 1)
    fi
    printf '%s' "$comm"
}

# @brief Decide whether a lease record is stale.
# @description
# A lease is alive only when its pid is still running (kill -0 succeeds) and its
# recorded comm matches the current comm of that pid. A dead pid, a comm
# mismatch (pid reuse), an unreadable record, or a malformed record is stale.
# A zombie that has exited but not yet been reaped still answers kill -0 and
# keeps /proc/<pid>/comm, so it stays counted as alive; pixied always waits for
# its children, so a released lease never lingers as a zombie.
#
# @arg $1 string The lease file path.
# @exitcode 0 When the lease is stale and should be removed.
# @exitcode 1 When the lease is alive.
pixied_lease_is_stale() {
    local path=$1 pid comm actual
    pid=$(pixied_lease_record_field "$path" pid)
    comm=$(pixied_lease_record_field "$path" comm)
    case "$pid" in
    '' | *[!0-9]*) return 0 ;;
    esac
    [ -n "$comm" ] || return 0
    kill -0 "$pid" 2>/dev/null || return 0
    actual=$(pixied_lease_proc_comm "$pid")
    [ "$actual" = "$comm" ] || return 0
    return 1
}

# @brief Remove a single lease file after validating it.
# @description
# Removes only a regular, owned, non-symlink lease file so a hostile entry
# cannot make the sweep delete something unexpected.
#
# @arg $1 string The lease file path to remove.
# @exitcode 0 When the file is removed.
# @exitcode 1 When the path is unsafe or removal fails.
pixied_lease_remove_file() {
    local path=$1
    if ! [ -f "$path" ] || [ -L "$path" ]; then
        pixied_die "lease removal target is not a regular file: $path"
    fi
    pixied_validate_owned_path "$path"
    pixied_run rm -f -- "$path"
}

# @brief Format alive lease entries for a message.
# @description
# Renders each 'pid|comm|kind|args' entry as an indented list line matching the
# plan message templates. When no entry is passed, formats the current
# PIXIED_LEASE_OTHER_LIST.
#
# @arg $@ string Optional lease entries to format.
# @stdout Zero or more lines of '  - pid <pid> (<comm>): <kind> <args>'.
# @exitcode 0 Always.
pixied_lease_format_entries() {
    local entries=("$@") entry pid comm kind args
    [ "${#entries[@]}" -gt 0 ] || entries=("${PIXIED_LEASE_OTHER_LIST[@]}")
    for entry in "${entries[@]}"; do
        [ -n "$entry" ] || continue
        IFS='|' read -r pid comm kind args <<<"$entry"
        printf '  - pid %s (%s): %s %s\n' "$pid" "$comm" "$kind" "$args"
    done
}

# @brief Sweep the lease directory, removing stale leases.
# @description
# Returns successfully when the lease directory does not exist. Otherwise it
# validates the directory, deletes every stale lease with a warning, and stores
# the alive leases in PIXIED_LEASE_ACTIVE_LIST as 'pid|comm|kind|args' entries.
# The directory itself is never removed. Non-regular entries such as
# subdirectories or symlinks are ignored without a warning; only the regular
# lease files this module creates are ever swept or listed.
#
# @set PIXIED_LEASE_ACTIVE_LIST array Alive lease entries after the sweep.
# @stdout Nothing (warnings go to stderr).
# @exitcode 0 When the sweep completes or the directory is absent.
# @exitcode 1 When a managed path or removal check fails.
pixied_lease_sweep() {
    local dir entry path pid comm kind args
    PIXIED_LEASE_ACTIVE_LIST=()
    dir=$(pixied_lease_dir)
    [ -d "$dir" ] || return 0
    pixied_validate_owned_path "$dir"
    for path in "$dir"/*; do
        [ -e "$path" ] || continue
        if ! [ -f "$path" ] || [ -L "$path" ]; then
            continue
        fi
        if pixied_lease_is_stale "$path"; then
            pid=$(pixied_lease_record_field "$path" pid)
            comm=$(pixied_lease_record_field "$path" comm)
            kind=$(pixied_lease_record_field "$path" kind)
            args=$(pixied_lease_record_field "$path" args)
            pixied_lease_remove_file "$path"
            pixied_warn "removed a stale PixiEden runtime lease: pid $pid ($comm) recorded as $kind $args is no longer running"
            continue
        fi
        pid=$(pixied_lease_record_field "$path" pid)
        comm=$(pixied_lease_record_field "$path" comm)
        kind=$(pixied_lease_record_field "$path" kind)
        args=$(pixied_lease_record_field "$path" args)
        PIXIED_LEASE_ACTIVE_LIST+=("$pid|$comm|$kind|$args")
    done
    return 0
}

# @brief List the pid chain from the current process to its roots.
# @description
# Walks parent pids from $$ upward, emitting one pid per line until it reaches
# pid 0 or 1 or detects a cycle (a repeated pid). Used to exclude a runtime's
# own ancestors from the "another runtime is active" check.
#
# @stdout One pid per line, starting with $$.
# @exitcode 0 Always.
pixied_lease_ancestor_pids() {
    local pid=$$ seen=" " ppid
    while [ -n "$pid" ] && [ "$pid" != 0 ] && [ "$pid" != 1 ]; do
        case "$seen" in
        *" $pid "*) break ;;
        esac
        printf '%s\n' "$pid"
        seen+="$pid "
        ppid=$(pixied_run ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
        case "$ppid" in
        '' | *[!0-9]*) break ;;
        esac
        pid=$ppid
    done
}

# @brief Count alive leases that are not on this process's ancestor chain.
# @description
# Scans PIXIED_LEASE_ACTIVE_LIST, dropping entries whose pid appears in
# pixied_lease_ancestor_pids (this process or its ancestors), and stores the
# remaining entries in PIXIED_LEASE_OTHER_LIST with their count in
# PIXIED_LEASE_OTHER_COUNT. Call it directly (not through command
# substitution) so the variables persist for pixied_lease_format_entries.
# Those remaining leases belong to other runtimes and gate uninstall.
#
# @set PIXIED_LEASE_OTHER_LIST array Non-ancestor alive lease entries.
# @set PIXIED_LEASE_OTHER_COUNT integer The number of non-ancestor alive leases.
# @stdout The number of non-ancestor alive leases.
# @exitcode 0 Always.
pixied_lease_other_active() {
    local ancestors entry pid found line count=0
    PIXIED_LEASE_OTHER_LIST=()
    ancestors=$(pixied_lease_ancestor_pids)
    for entry in "${PIXIED_LEASE_ACTIVE_LIST[@]}"; do
        [ -n "$entry" ] || continue
        pid=${entry%%|*}
        found=0
        while IFS= read -r line; do
            [ "$line" = "$pid" ] && found=1 && break
        done <<<"$ancestors"
        if [ "$found" -eq 0 ]; then
            PIXIED_LEASE_OTHER_LIST+=("$entry")
            count=$((count + 1))
        fi
    done
    # shellcheck disable=SC2034 # Read by pixied_uninstall_require_no_active_lease.
    PIXIED_LEASE_OTHER_COUNT=$count
    printf '%s' "$count"
}

# @brief Acquire a runtime lease for this process.
# @description
# Creates a uniquely named, private lease file recording this pid, comm, kind,
# and (for run) a short argument preview, then exports PIXIED_LEASE_FILE so the
# EXIT trap can release it. A sibling runtime's existing lease never blocks
# acquisition.
#
# @arg $1 string The runtime kind: shell or run.
# @arg $2 string The args preview to record (empty for shell).
# @set PIXIED_LEASE_FILE string The created lease file path.
# @exitcode 0 When the lease is created.
# @exitcode 1 When the kind is invalid or the lease cannot be created.
pixied_lease_acquire() {
    local kind=${1:-} args=${2:-} dir lease file comm
    case "$kind" in
    shell | run) ;;
    *) pixied_die "invalid lease kind: $kind" ;;
    esac
    dir=$(pixied_lease_dir)
    pixied_run mkdir -p -- "$dir" ||
        pixied_die "could not create lease directory: $dir"
    pixied_run chmod 0700 -- "$dir" ||
        pixied_die "could not protect lease directory: $dir"
    pixied_validate_owned_path "$dir"
    comm=$(pixied_lease_proc_comm $$)
    file=$(pixied_run mktemp --tmpdir="$dir" "$$-XXXXXX") ||
        pixied_die "could not create a lease file in: $dir"
    lease=$file
    {
        printf 'pid=%s\n' "$$"
        printf 'comm=%s\n' "$comm"
        printf 'kind=%s\n' "$kind"
        printf 'args=%s\n' "$args"
    } >"$lease"
    pixied_run chmod 0600 -- "$lease" || {
        pixied_run rm -f -- "$lease"
        pixied_die "could not protect lease file: $lease"
    }
    PIXIED_LEASE_FILE=$lease
    export PIXIED_LEASE_FILE
}

# @brief Release this process's runtime lease.
# @description
# Removes the lease file recorded in PIXIED_LEASE_FILE and clears the variable.
# A no-op when no lease is held.
#
# @set PIXIED_LEASE_FILE string Becomes an empty string after release.
# @exitcode 0 Always.
pixied_lease_release() {
    [ -n "${PIXIED_LEASE_FILE:-}" ] || return 0
    pixied_run rm -f -- "$PIXIED_LEASE_FILE"
    PIXIED_LEASE_FILE=""
}
