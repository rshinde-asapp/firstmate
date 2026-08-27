# shellcheck shell=bash
# Fused backlog transitions for the scripts that own a task's physical record.
# Usage: . bin/fm-tasks-axi-lib.sh; . bin/fm-backlog-transition-lib.sh
# (this library reads that one's backend gate and never sources it itself, so a
# caller that already sourced it keeps its memoised compatibility verdict).
#
# INVARIANT. `state/<id>.meta` exists <=> this home's backlog row for <id> is In
# flight. The script performing the mechanical record change owns the paired
# backlog transition and runs it in the same process, under the per-task meta
# lock it already holds, before it reports success. Nothing else - not a later
# agent turn, not a printed reminder - is load-bearing for the pairing.
#   bin/fm-spawn.sh      meta published  => `tasks-axi start`
#   bin/fm-teardown.sh   `tasks-axi done` => meta removed
#   bin/fm-bootstrap.sh  replays whatever a crash left behind, THIS HOME ONLY.
# bin/fm-fleet-snapshot.sh's classifier and bin/fm-secondmate-reconcile.sh's
# cross-home nudge stay defense in depth, not the primary mechanism.
#
# SCOPE. fm_backlog_transition_applies is the single gate. It excludes
# secondmates (persistent agents are never backlog items, AGENTS.md section 10),
# homes whose configured backlog backend is manual or whose tasks-axi is not
# compatible (bin/fm-tasks-axi-lib.sh), and homes that keep no backlog file at
# all. A skipped transition is never an error; the caller reports the manual
# follow-up instead.
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

# Set by fm_backlog_transition_applies when it returns non-zero.
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

fm_backlog_file() {  # <data-dir>
  printf '%s/backlog.md\n' "$1"
}

# The directory a backlog's own `.tasks.toml` is resolved from.
fm_backlog_root() {  # <data-dir>
  local data=$1 parent
  parent=${data%/*}
  [ "$parent" != "$data" ] && [ -n "$parent" ] || parent=.
  printf '%s\n' "$parent"
}

fm_backlog_data_relative() {  # <data-dir>
  local data=${1%/} root
  root=$(fm_backlog_root "$data") || return 1
  case "$data" in
    "$root"/*) printf '%s\n' "${data#"$root"/}" ;;
    *) printf '%s\n' "$data" ;;
  esac
}

fm_backlog_transition_applies() {  # <config-dir> <data-dir> <kind>
  local config=$1 data=$2 kind=$3 file
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
  file=$(fm_backlog_file "$data")
  if [ ! -f "$file" ]; then
    FM_BACKLOG_TRANSITION_SKIP="this home keeps no backlog at $file"
    return 1
  fi
  return 0
}

fm_backlog_row_probe() {  # <data-dir> <id>
  local data=$1 id=$2 out state held
  FM_BACKLOG_ROW_RESULT=error
  FM_BACKLOG_ROW_STATE=
  FM_BACKLOG_ROW_ERROR=
  if ! out=$(tasks-axi show "$id" --file "$(fm_backlog_file "$data")" 2>&1); then
    if printf '%s\n' "$out" | grep -q '^code: NOT_FOUND$'; then
      FM_BACKLOG_ROW_RESULT=not_found
    else
      FM_BACKLOG_ROW_ERROR=$(printf '%s\n' "$out" | sed -n '1p')
      [ -n "$FM_BACKLOG_ROW_ERROR" ] \
        || FM_BACKLOG_ROW_ERROR="tasks-axi show $id failed with no output"
    fi
    return 1
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
  local data=$1 verb=$2 id=$3 out
  shift 3
  FM_BACKLOG_TRANSITION_ERROR=
  if out=$(cd "$(fm_backlog_root "$data")" 2>/dev/null && tasks-axi "$verb" "$id" \
      --file "$(fm_backlog_file "$data")" "$@" 2>&1); then
    return 0
  fi
  FM_BACKLOG_TRANSITION_ERROR=$(printf '%s\n' "$out" | sed -n '1p')
  [ -n "$FM_BACKLOG_TRANSITION_ERROR" ] \
    || FM_BACKLOG_TRANSITION_ERROR="tasks-axi $verb $id failed with no output"
  return 1
}

fm_backlog_start() {  # <data-dir> <id>
  fm_backlog_mutate "$1" start "$2"
}

fm_backlog_done() {  # <data-dir> <id> [flag...]
  local data=$1 id=$2
  shift 2
  fm_backlog_mutate "$data" "done" "$id" "$@"
}

fm_backlog_close_marker_path() {  # <state-dir> <id>
  printf '%s/%s.backlog-close\n' "$1" "$2"
}

# Record the exact close a teardown is about to perform. Refuses an argument
# carrying a newline rather than writing a record that cannot be read back.
fm_backlog_close_marker_write() {  # <state-dir> <id> <data-dir> <spawn-gen> [flag...]
  local state=$1 id=$2 data=$3 spawn_gen=$4 marker tmp arg
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
  mv -f "$tmp" "$marker" || { rm -f "$tmp"; return 1; }
  return 0
}

fm_backlog_close_marker_clear() {  # <state-dir> <id>
  rm -f "$(fm_backlog_close_marker_path "$1" "$2")" 2>/dev/null || true
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
      rm -f "$marker" 2>/dev/null || true
      FM_BACKLOG_CLOSE_REPLAY_RESULT=stale
      return 0
    fi
    rm -f "$state/$id.meta"
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
      rm -f "$marker" 2>/dev/null || true
      FM_BACKLOG_CLOSE_REPLAY_RESULT=stale
      return 0
      ;;
  esac
  if fm_backlog_done "$data" "$id" "${args[@]+"${args[@]}"}"; then
    rm -f "$marker" 2>/dev/null || true
    FM_BACKLOG_CLOSE_REPLAY_RESULT=closed
    return 0
  fi
  return 1
}
