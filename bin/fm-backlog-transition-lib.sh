# shellcheck shell=bash
# Fused backlog transitions for the scripts that own a task's physical record.
# Usage: . bin/fm-tasks-axi-lib.sh; . bin/fm-backlog-transition-lib.sh
# (this library reads that one's backend gate and never sources it itself, so a
# caller that already sourced it keeps its memoised compatibility verdict).
#
# INVARIANT. In ordinary successful lifecycle state, `state/<id>.meta` exists
# <=> this home's backlog row for <id> is In flight; the one teardown crash
# window is represented by `state/<id>.backlog-close`. The script performing the
# mechanical record change owns the paired backlog transition and runs it in the
# same process, under the per-task meta lock it already holds, before it reports
# success. Nothing else - not a later agent turn, not a printed reminder - is
# load-bearing for the pairing.
#   bin/fm-spawn.sh      meta published => `tasks-axi start`
#   bin/fm-teardown.sh   meta removed => `tasks-axi done`
#   bin/fm-bootstrap.sh  replays whatever a crash left behind, THIS HOME ONLY.
# bin/fm-fleet-snapshot.sh's classifier and bin/fm-secondmate-reconcile.sh's
# cross-home nudge stay defense in depth, not the primary mechanism.
#
# SCOPE. fm_backlog_transition_applies is the single gate. It excludes
# secondmates (persistent agents are never backlog items, AGENTS.md section 10),
# homes whose configured backlog backend is manual or whose tasks-axi is not
# compatible (bin/fm-tasks-axi-lib.sh), and homes that keep no backlog file at
# all. Those return-1 exemptions are never errors; an unresolvable configured
# data directory instead returns 2 so callers refuse before mutation.
#
# ADDRESSING. Every call passes `--file <data>/backlog.md` so the mutation lands
# in the home that owns the task regardless of the caller's working directory,
# and runs from that data directory's parent so the same home's `.tasks.toml`
# supplies done_keep and the archive path. The parent of the data directory is
# the addressing root rather than FM_HOME, so a home whose data directory is
# relocated keeps its backlog and its archive together. A root with no
# `.tasks.toml` gets tasks-axi's built-in defaults.
#
# CRASH RECOVERY. Only teardown needs a durable record: it removes the meta and
# with it the completion links, so a process killed between the two halves would
# leave nothing to reconstruct the close from. It writes
# `state/<id>.backlog-close` first, and removes it once the close lands.
# fm_backlog_close_marker_replay re-runs exactly that close; `tasks-axi done` on
# an already-closed task backfills links without moving the close date, so replay
# is idempotent. Spawn needs no marker: it publishes the meta first, so a crash
# leaves the meta itself as the evidence that the row is owed a start.

# Set by fm_backlog_transition_applies for a return-1 exemption.
# shellcheck disable=SC2034 # Output global, read by the sourcing caller.
FM_BACKLOG_TRANSITION_SKIP=
# Set by the mutating helpers when they return non-zero.
FM_BACKLOG_TRANSITION_ERROR=
FM_BACKLOG_ROW_RESULT=
FM_BACKLOG_ROW_STATE=
FM_BACKLOG_ROW_ERROR=
# Set by fm_backlog_close_marker_replay: closed | stale | noop.
# shellcheck disable=SC2034 # Output global, read by the sourcing caller.
FM_BACKLOG_CLOSE_REPLAY_RESULT=

fm_backlog_data_absolute() {
  local data=$1
  if ! data=$(CDPATH='' cd -- "$data" 2>/dev/null && pwd -P); then
    return 1
  fi
  printf '%s\n' "$data"
}

fm_backlog_file() {  # <data-dir>
  local data
  data=$(fm_backlog_data_absolute "$1") || {
    FM_BACKLOG_TRANSITION_ERROR="data directory cannot be resolved: $1"
    return 1
  }
  if [ "$data" = / ]; then
    printf '/backlog.md\n'
  else
    printf '%s/backlog.md\n' "$data"
  fi
}

# The directory a backlog's own `.tasks.toml` is resolved from.
fm_backlog_root() {  # <data-dir>
  local data parent
  data=$(fm_backlog_data_absolute "$1") || {
    FM_BACKLOG_TRANSITION_ERROR="data directory cannot be resolved: $1"
    return 1
  }
  case "$data" in
    */*)
      parent=${data%/*}
      [ -n "$parent" ] || parent=/
      ;;
    *) parent=. ;;
  esac
  printf '%s\n' "$parent"
}

fm_backlog_data_relative() {  # <data-dir>
  local data root
  data=$(fm_backlog_data_absolute "$1") || {
    FM_BACKLOG_TRANSITION_ERROR="data directory cannot be resolved: $1"
    return 1
  }
  root=$(fm_backlog_root "$data") || return 1
  if [ "$data" = "$root" ]; then
    printf '.\n'
    return 0
  fi
  if [ "$root" = / ]; then
    printf '%s\n' "${data#/}"
    return 0
  fi
  case "$data" in
    "$root"/*) printf '%s\n' "${data#"$root"/}" ;;
    *) printf '%s\n' "$data" ;;
  esac
}

fm_backlog_transition_applies() {  # <config-dir> <data-dir> <kind>
  local config=$1 data kind=$3 file
  FM_BACKLOG_TRANSITION_SKIP=
  if [ "$kind" = secondmate ]; then
    FM_BACKLOG_TRANSITION_SKIP="secondmates are not backlog items"
    return 1
  fi
  if fm_backlog_backend_manual "$config"; then
    FM_BACKLOG_TRANSITION_SKIP="config/backlog-backend selects manual editing"
    return 1
  fi
  if ! fm_tasks_axi_compatible; then
    FM_BACKLOG_TRANSITION_SKIP="no compatible tasks-axi on PATH"
    return 1
  fi
  if ! data=$(fm_backlog_data_absolute "$2"); then
    FM_BACKLOG_TRANSITION_ERROR="data directory cannot be resolved: $2"
    return 2
  fi
  file=$(fm_backlog_file "$data")
  if [ ! -f "$file" ]; then
    FM_BACKLOG_TRANSITION_SKIP="this home keeps no backlog at $file"
    return 1
  fi
  return 0
}

fm_backlog_row_probe() {  # <data-dir> <id>
  local data id=$2 out state held command_status
  if ! data=$(fm_backlog_data_absolute "$1"); then
    FM_BACKLOG_ROW_RESULT=error
    FM_BACKLOG_ROW_STATE=
    FM_BACKLOG_ROW_ERROR="data directory cannot be resolved: $1"
    return 1
  fi
  FM_BACKLOG_ROW_RESULT=error
  FM_BACKLOG_ROW_STATE=
  FM_BACKLOG_ROW_ERROR=
  out=$(cd "$(fm_backlog_root "$data")" 2>/dev/null && tasks-axi show "$id" \
      --file "$(fm_backlog_file "$data")" 2>&1)
  command_status=$?
  if [ "$command_status" -ne 0 ]; then
    if printf '%s\n' "$out" | grep -q '^code: NOT_FOUND$'; then
      FM_BACKLOG_ROW_RESULT=not_found
    else
      FM_BACKLOG_ROW_ERROR=$(printf '%s\n' "$out" | sed -n '1p')
      [ -n "$FM_BACKLOG_ROW_ERROR" ] \
        || FM_BACKLOG_ROW_ERROR="tasks-axi show $id failed with no output"
    fi
    return "$command_status"
  fi
  state=$(printf '%s\n' "$out" | sed -n 's/^  state: *//p' | head -1)
  held=$(printf '%s\n' "$out" | sed -n 's/^  held: *//p' | head -1)
  if [ -z "$state" ]; then
    FM_BACKLOG_ROW_ERROR="tasks-axi show $id returned no state"
    return 1
  fi
  FM_BACKLOG_ROW_RESULT=found
  FM_BACKLOG_ROW_STATE="$state ${held:-no}"
  return 0
}

# Echo "<state> <held>" for one row, e.g. "queued no" / "in_flight yes".
# Returns 1 when the row does not exist or cannot be read.
fm_backlog_row_state() {  # <data-dir> <id>
  fm_backlog_row_probe "$1" "$2" || return 1
  printf '%s\n' "$FM_BACKLOG_ROW_STATE"
}

# Run one tasks-axi mutation against <home>'s backlog, capturing its first
# output line in FM_BACKLOG_TRANSITION_ERROR on failure.
fm_backlog_mutate() {  # <data-dir> <verb> <id> [flag...]
  local data verb=$2 id=$3 out command_status
  if ! data=$(fm_backlog_data_absolute "$1"); then
    FM_BACKLOG_TRANSITION_ERROR="data directory cannot be resolved: $1"
    return 1
  fi
  shift 3
  FM_BACKLOG_TRANSITION_ERROR=
  out=$(cd "$(fm_backlog_root "$data")" 2>/dev/null && tasks-axi "$verb" "$id" \
      --file "$(fm_backlog_file "$data")" "$@" 2>&1)
  command_status=$?
  [ "$command_status" -ne 0 ] || return 0
  FM_BACKLOG_TRANSITION_ERROR=$(printf '%s\n' "$out" | sed -n '1p')
  [ -n "$FM_BACKLOG_TRANSITION_ERROR" ] \
    || FM_BACKLOG_TRANSITION_ERROR="tasks-axi $verb $id failed with no output"
  return "$command_status"
}

fm_backlog_start() {  # <data-dir> <id>
  fm_backlog_mutate "$1" start "$2"
}

fm_backlog_done() {  # <data-dir> <id> [flag...]
  local data=$1 id=$2
  shift 2
  fm_backlog_mutate "$data" "done" "$id" "$@"
}

fm_backlog_record_present() {
  local path=$1
  if [ ! -f "$path" ] || [ -L "$path" ]; then
    FM_BACKLOG_TRANSITION_ERROR="task record publication did not land at $path"
    return 1
  fi
  return 0
}

fm_backlog_record_remove() {
  local path=$1 label=$2
  if ! rm -f "$path" 2>/dev/null || [ -e "$path" ] || [ -L "$path" ]; then
    FM_BACKLOG_TRANSITION_ERROR="$label could not be removed at $path"
    return 1
  fi
  return 0
}

fm_backlog_record_publish() {
  local source=$1 target=$2 label=$3
  if ! mv -f "$source" "$target" 2>/dev/null || ! fm_backlog_record_present "$target"; then
    [ -n "$FM_BACKLOG_TRANSITION_ERROR" ] \
      || FM_BACKLOG_TRANSITION_ERROR="$label publication failed at $target"
    return 1
  fi
  return 0
}

fm_backlog_dispatch_transition() {
  local meta=$1 data=$2 id=$3 row row_status
  fm_backlog_record_present "$meta" || return 1
  fm_backlog_row_probe "$data" "$id"
  row_status=$?
  if [ "$row_status" -ne 0 ]; then
    if [ "$FM_BACKLOG_ROW_RESULT" = not_found ]; then
      FM_BACKLOG_TRANSITION_ERROR="backlog item $id vanished before dispatch commit"
    else
      FM_BACKLOG_TRANSITION_ERROR=$FM_BACKLOG_ROW_ERROR
    fi
    return "$row_status"
  fi
  row=$FM_BACKLOG_ROW_STATE
  case "$row" in
    in_flight\ *) return 0 ;;
    queued\ no) fm_backlog_start "$data" "$id" ;;
    *)
      FM_BACKLOG_TRANSITION_ERROR="backlog item $id is not dispatchable in state $row"
      return 1
      ;;
  esac
}

fm_backlog_dispatch_rollback() {
  local meta=$1 busy_script=$2 state=$3 id=$4 gen=$5 failed=0
  fm_backlog_record_remove "$meta" "provisional task record" || failed=1
  if [ -n "$gen" ]; then
    "$busy_script" retire "$state" "$id" --gen "$gen" >/dev/null 2>&1 || failed=1
    if [ -e "$state/$id.busy-state" ] || [ -L "$state/$id.busy-state" ] \
       || [ -e "$state/$id.busy-gen" ] || [ -L "$state/$id.busy-gen" ]; then
      failed=1
    fi
  fi
  if [ "$failed" -ne 0 ]; then
    FM_BACKLOG_TRANSITION_ERROR="failed-dispatch cleanup did not remove both task and busy records for $id"
    return 1
  fi
  return 0
}

fm_backlog_close_transition() {
  local meta=$1 marker=$2 data=$3 id=$4
  shift 4
  [ -z "$meta" ] || fm_backlog_record_remove "$meta" "task record" || return 1
  fm_backlog_done "$data" "$id" "$@" || return 1
  fm_backlog_record_remove "$marker" "pending-close record"
}

fm_backlog_atomic_transition() {
  local operation=$1
  shift
  case "$operation" in
    publish) fm_backlog_record_publish "$@" ;;
    verify-published) fm_backlog_record_present "$@" ;;
    remove) fm_backlog_record_remove "$@" ;;
    dispatch) fm_backlog_dispatch_transition "$@" ;;
    rollback) fm_backlog_dispatch_rollback "$@" ;;
    close) fm_backlog_close_transition "$@" ;;
    *) FM_BACKLOG_TRANSITION_ERROR="unknown backlog atomic transition $operation"; return 2 ;;
  esac
}

fm_backlog_close_marker_path() {  # <state-dir> <id>
  printf '%s/%s.backlog-close\n' "$1" "$2"
}

# Record the exact close a teardown is about to perform. Refuses an argument
# carrying a newline rather than writing a record that cannot be read back.
fm_backlog_close_marker_write() {  # <state-dir> <id> <data-dir> <spawn-gen> [flag...]
  local state=$1 id=$2 data spawn_gen=$4 marker tmp arg
  if ! data=$(fm_backlog_data_absolute "$3"); then
    FM_BACKLOG_TRANSITION_ERROR="data directory cannot be resolved: $3"
    return 1
  fi
  shift 4
  marker=$(fm_backlog_close_marker_path "$state" "$id") || return 1
  tmp="$state/.$id.backlog-close.${BASHPID:-$$}"
  {
    printf 'id=%s\n' "$id"
    printf 'data=%s\n' "$data"
    printf 'spawn_gen=%s\n' "$spawn_gen"
    for arg in "$@"; do
      case "$arg" in
        *$'\n'*) return 1 ;;
      esac
      printf 'arg=%s\n' "$arg"
    done
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  fm_backlog_atomic_transition publish "$tmp" "$marker" "pending-close record" \
    || { rm -f "$tmp"; return 1; }
}

fm_backlog_close_marker_remove() {  # <marker-path>
  fm_backlog_atomic_transition remove "$1" "pending-close record"
}

fm_backlog_close_marker_clear() {  # <state-dir> <id>
  local marker
  marker=$(fm_backlog_close_marker_path "$1" "$2") || return 1
  fm_backlog_close_marker_remove "$marker"
}

# Replay one recorded close. Returns 0 when the row is closed (or the record is
# no longer actionable), 1 when the close itself failed.
fm_backlog_close_marker_replay() {  # <state-dir> <marker-path>
  local state=$1 marker=$2 id='' data='' marker_spawn_gen='' meta_spawn_gen line row_state
  local args=()
  FM_BACKLOG_CLOSE_REPLAY_RESULT=noop
  [ -f "$marker" ] || return 0
  while IFS= read -r line; do
    case "$line" in
      id=*) id=${line#id=} ;;
      data=*) data=${line#data=} ;;
      spawn_gen=*) marker_spawn_gen=${line#spawn_gen=} ;;
      arg=*) args+=("${line#arg=}") ;;
    esac
  done < "$marker"
  if [ -z "$id" ] || [ -z "$data" ]; then
    FM_BACKLOG_TRANSITION_ERROR="unreadable pending-close record $marker"
    return 1
  fi
  if [ -e "$state/$id.meta" ]; then
    meta_spawn_gen=$(sed -n 's/^spawn_gen=//p' "$state/$id.meta" | head -1)
    if [ -z "$marker_spawn_gen" ] || [ "$meta_spawn_gen" != "$marker_spawn_gen" ]; then
      fm_backlog_close_marker_remove "$marker" || return 1
      FM_BACKLOG_CLOSE_REPLAY_RESULT=stale
      return 0
    fi
    fm_backlog_atomic_transition remove "$state/$id.meta" "the interrupted task record" \
      || return 1
  fi
  if fm_backlog_row_probe "$data" "$id"; then
    row_state=$FM_BACKLOG_ROW_STATE
  else
    if [ "$FM_BACKLOG_ROW_RESULT" != not_found ]; then
      FM_BACKLOG_TRANSITION_ERROR=$FM_BACKLOG_ROW_ERROR
      return 1
    fi
    row_state=
  fi
  case "$row_state" in
    done\ *|'')
      # Already closed, or the row is gone entirely: nothing is owed.
      fm_backlog_close_marker_remove "$marker" || return 1
      FM_BACKLOG_CLOSE_REPLAY_RESULT=stale
      return 0
      ;;
  esac
  if fm_backlog_atomic_transition close '' "$marker" "$data" "$id" \
      "${args[@]+"${args[@]}"}"; then
    FM_BACKLOG_CLOSE_REPLAY_RESULT=closed
    return 0
  fi
  return 1
}
