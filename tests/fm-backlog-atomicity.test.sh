#!/usr/bin/env bash
# Behavior tests for the backlog<->record pairing invariant:
# `state/<id>.meta` exists <=> this home's backlog row for that id is In flight.
#
# bin/fm-backlog-transition-lib.sh states the contract; the three scripts that
# own a task's physical record enforce it. These tests drive those real scripts
# against a real backlog file and the real tasks-axi CLI, and assert the
# resulting RECORD STATE - never the wording of a reminder a later turn was
# expected to act on, which is exactly what let the two records drift before.
#
#   dispatch    bin/fm-spawn.sh moves the row In flight in the same run that
#               publishes the record, so a live worker the backlog does not own
#               cannot arise on the ordinary path.
#   completion  bin/fm-teardown.sh closes the row before it reports success, so
#               a finished task cannot be left showing as running.
#   recovery    bin/fm-bootstrap.sh reconciles THIS home's own books at session
#               start, covering the millisecond crash window inside those two
#               scripts and any drift a home was already carrying.
#
# The invariant is single-host: a home's backlog and its records live together,
# so a persistent secondmate keeps its own books through its own copies of these
# scripts. A parent's view of a mate lagging is a freshness question and is
# deliberately not asserted here.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
BOOTSTRAP="$ROOT/bin/fm-bootstrap.sh"
TMP_ROOT=$(fm_test_tmproot fm-backlog-atomicity)

command -v tasks-axi >/dev/null 2>&1 || {
  printf 'ok - skipped (tasks-axi is not installed; the fused transitions are inert without it)\n'
  exit 0
}

# --- fixture ----------------------------------------------------------------

# A home with a real backlog, a real project clone with an origin, a pooled
# worktree, and stubs for every tool the spawn path shells out to.
make_home() {  # <name> [task-id...]
  local name=$1 case_dir home fakebin id
  shift
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  fakebin=$(fm_fakebin "$case_dir")
  mkdir -p "$home/state" "$home/config" "$home/data" "$home/projects"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' claude > "$home/config/crew-harness"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' \
    > "$home/data/backlog.md"
  for id in "$@"; do
    mkdir -p "$home/data/$id"
    printf 'Delivery contract: mode=no-mistakes\nbrief for %s\n' "$id" > "$home/data/$id/brief.md"
  done

  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;; esac
case "${1:-}" in display-message) printf 'firstmate\n'; exit 0 ;; esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh gh-axi no-mistakes

  fm_git_init_commit "$case_dir/project"
  fm_git_add_origin "$case_dir/project" "$case_dir/project.origin.git"
  git -C "$case_dir/project" worktree add --quiet -b pooled "$case_dir/wt"

  printf '%s\n' "$case_dir"
}

home_of() { printf '%s/home\n' "$1"; }
backlog_of() { printf '%s/home/data/backlog.md\n' "$1"; }

add_item() {  # <case-dir> <id> [kind]
  tasks-axi add "$2" "item for $2" --kind "${3:-ship}" --file "$(backlog_of "$1")" >/dev/null
}

start_item() {  # <case-dir> <id>
  tasks-axi start "$2" --file "$(backlog_of "$1")" >/dev/null
}

row_state() {  # <case-dir> <id>
  tasks-axi show "$2" --file "$(backlog_of "$1")" 2>/dev/null |
    sed -n 's/^  state: *//p' | head -1
}

# Shadow tasks-axi with a wrapper that fails one verb and delegates every other
# verb to the real binary, so a test can drive a genuine mid-transition failure
# without faking the reads around it.
break_verb() {  # <case-dir> <verb>
  local case_dir=$1 verb=$2 real
  real=$(command -v tasks-axi)
  cat > "$case_dir/fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = "$verb" ]; then
  echo 'error: "backlog is unwritable"' >&2
  exit 1
fi
exec "$real" "\$@"
SH
  chmod +x "$case_dir/fakebin/tasks-axi"
}

change_row_on_second_show() {  # <case-dir> <done|rm>
  local case_dir=$1 action=$2 real
  real=$(command -v tasks-axi)
  cat > "$case_dir/fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = show ]; then
  count=0
  [ ! -f "$case_dir/show-count" ] || count=\$(cat "$case_dir/show-count")
  count=\$((count + 1))
  printf '%s\n' "\$count" > "$case_dir/show-count"
  if [ "\$count" -eq 2 ]; then
    "$real" "$action" "\$2" --file "\$4" >/dev/null || exit 1
  fi
fi
exec "$real" "\$@"
SH
  chmod +x "$case_dir/fakebin/tasks-axi"
}

break_launch_delivery() {  # <case-dir>
  local case_dir=$1
  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;; esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  send-keys) exit 1 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"
}

break_meta_removal() {  # <case-dir> <meta-path>
  local case_dir=$1 meta=$2 real
  real=$(command -v rm)
  cat > "$case_dir/fakebin/rm" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  [ "\$arg" != "$meta" ] || exit 1
done
exec "$real" "\$@"
SH
  chmod +x "$case_dir/fakebin/rm"
}

write_task_meta() {  # <case-dir> <id> <kind> <mode> [extra-line...]
  local case_dir=$1 id=$2 kind=$3 mode=$4
  shift 4
  fm_write_meta "$(home_of "$case_dir")/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$case_dir/absent-worktree" \
    "project=$case_dir/absent-project" \
    "harness=claude" \
    "kind=$kind" \
    "mode=$mode" \
    "yolo=off" \
    "$@"
}

run_spawn() {  # <case-dir> <args...>
  local case_dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$(home_of "$case_dir")" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$case_dir/wt" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR='' \
    PATH="$case_dir/fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

run_ship_spawn() {  # <case-dir> <id>
  local case_dir=$1 id=$2
  run_spawn "$case_dir" "$id" "$case_dir/project" --mode no-mistakes --yolo off
}

# Teardown against a recorded worktree that no longer exists: the landed-work and
# worktree-return steps are then no-ops, which keeps these cases about the
# backlog transition rather than re-testing tests/fm-teardown.test.sh's matrix.
run_teardown() {  # <case-dir> <id> [args...]
  local case_dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$(home_of "$case_dir")" \
    PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" "$@" 2>&1
}

run_bootstrap() {  # <case-dir>
  local case_dir=$1
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$(home_of "$case_dir")" \
    FM_BOOTSTRAP_NETWORK=skip \
    PATH="$case_dir/fakebin:$PATH" \
    "$BOOTSTRAP" 2>&1
}

# --- dispatch ---------------------------------------------------------------

test_dispatch_moves_the_item_in_flight_in_the_same_run() {
  local case_dir id out
  id=atomic-dispatch-b1
  case_dir=$(make_home dispatch-ok "$id")
  add_item "$case_dir" "$id"

  out=$(run_ship_spawn "$case_dir" "$id") || fail "spawn failed: $out"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_present "$(home_of "$case_dir")/state/$id.meta" "spawn published no record"
  [ "$(row_state "$case_dir" "$id")" = in_flight ] \
    || fail "spawn reported success with its backlog item still $(row_state "$case_dir" "$id")"
  pass "dispatch publishes the record and moves the backlog item In flight in one run"
}

test_dispatch_refuses_an_id_this_home_has_no_item_for() {
  local case_dir id out rc=0
  id=atomic-dispatch-b2
  case_dir=$(make_home dispatch-no-item "$id")

  out=$(run_ship_spawn "$case_dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "spawn dispatched work no backlog item owns"
  assert_contains "$out" "no backlog item in this home" \
    "spawn refused without naming the missing backlog item"
  assert_absent "$(home_of "$case_dir")/state/$id.meta" \
    "refused dispatch still left a record behind"
  pass "dispatch refuses, before creating anything, when the home has no item for the id"
}

test_dispatch_refuses_a_closed_item() {
  local case_dir id out rc=0
  id=atomic-dispatch-b3
  case_dir=$(make_home dispatch-closed "$id")
  add_item "$case_dir" "$id"
  tasks-axi "done" "$id" --file "$(backlog_of "$case_dir")" >/dev/null

  out=$(run_ship_spawn "$case_dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "spawn dispatched onto an item the backlog already closed"
  [ "$(row_state "$case_dir" "$id")" = "done" ] \
    || fail "refused dispatch silently reopened a closed item"
  assert_absent "$(home_of "$case_dir")/state/$id.meta" \
    "refused dispatch onto a closed item still left a record behind"
  pass "dispatch refuses a closed item instead of silently reopening it"
}

test_dispatch_leaves_no_record_when_the_transition_fails() {
  local case_dir id out rc=0
  id=atomic-dispatch-b4
  case_dir=$(make_home dispatch-transition-fails "$id")
  add_item "$case_dir" "$id"
  break_verb "$case_dir" start

  out=$(run_ship_spawn "$case_dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "spawn reported success though the backlog transition failed"
  assert_contains "$out" "could not be moved to In flight" \
    "spawn failed without explaining the backlog transition failure"
  assert_absent "$(home_of "$case_dir")/state/$id.meta" \
    "a failed backlog transition left an orphaned record behind"
  assert_absent "$(home_of "$case_dir")/state/$id.busy-state" \
    "a failed backlog transition left the task's armed busy generation behind"
  [ "$(row_state "$case_dir" "$id")" = queued ] \
    || fail "a failed dispatch left the backlog item in $(row_state "$case_dir" "$id")"
  pass "a failed backlog transition fails the dispatch loudly and leaves no record"
}

test_dispatch_rolls_back_before_a_failed_launch_delivery() {
  local case_dir id out rc=0
  id=atomic-dispatch-delivery-fails-b5
  case_dir=$(make_home dispatch-delivery-fails "$id")
  add_item "$case_dir" "$id"
  break_launch_delivery "$case_dir"

  out=$(run_ship_spawn "$case_dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "spawn reported success though launch delivery failed"
  assert_absent "$(home_of "$case_dir")/state/$id.meta" \
    "a failed launch delivery left its provisional record behind"
  assert_absent "$(home_of "$case_dir")/state/$id.busy-state" \
    "a failed launch delivery left its provisional busy generation behind"
  [ "$(row_state "$case_dir" "$id")" = queued ] \
    || fail "launch delivery failed after committing backlog state $(row_state "$case_dir" "$id")"
  pass "dispatch commits neither record nor backlog state before launch delivery succeeds"
}

test_dispatch_does_not_resurrect_a_row_closed_after_preflight() {
  local case_dir id out rc=0
  id=atomic-dispatch-closed-race-b5
  case_dir=$(make_home dispatch-closed-race "$id")
  add_item "$case_dir" "$id"
  change_row_on_second_show "$case_dir" "done"

  out=$(run_ship_spawn "$case_dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "spawn succeeded after its backlog row was closed"
  assert_contains "$out" "state done" "spawn did not report the row's ineligible state"
  [ "$(row_state "$case_dir" "$id")" = "done" ] \
    || fail "spawn resurrected a row closed after preflight"
  assert_absent "$(home_of "$case_dir")/state/$id.meta" \
    "spawn retained a record after its row was closed"
  pass "dispatch does not resurrect a row closed after preflight"
}

test_dispatch_fails_when_its_row_vanishes_after_preflight() {
  local case_dir id out rc=0
  id=atomic-dispatch-removed-race-b6
  case_dir=$(make_home dispatch-removed-race "$id")
  add_item "$case_dir" "$id"
  change_row_on_second_show "$case_dir" rm

  out=$(run_ship_spawn "$case_dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "spawn succeeded after its backlog row vanished"
  assert_contains "$out" "vanished before dispatch commit" \
    "spawn did not report that its backlog row vanished"
  assert_absent "$(home_of "$case_dir")/state/$id.meta" \
    "spawn retained a record after its backlog row vanished"
  [ -z "$(row_state "$case_dir" "$id")" ] || fail "spawn recreated a removed backlog row"
  pass "dispatch fails when its backlog row vanishes after preflight"
}

# --- completion -------------------------------------------------------------

test_completion_closes_a_local_only_ship_before_reporting_success() {
  local case_dir id out
  id=atomic-close-b5
  case_dir=$(make_home close-local-only)
  add_item "$case_dir" "$id"
  start_item "$case_dir" "$id"
  write_task_meta "$case_dir" "$id" ship local-only

  out=$(run_teardown "$case_dir" "$id") || fail "teardown failed: $out"
  [ "$(row_state "$case_dir" "$id")" = "done" ] \
    || fail "teardown reported success with the item still $(row_state "$case_dir" "$id")"
  assert_grep 'local main' "$(backlog_of "$case_dir")" \
    "a local-only landing was closed without its local-main note"
  pass "completion closes a local-only ship, with its landing note, before reporting success"
}

test_completion_closes_a_scout_with_its_report() {
  local case_dir id out
  id=atomic-close-b6
  case_dir=$(make_home close-scout)
  add_item "$case_dir" "$id" scout
  start_item "$case_dir" "$id"
  write_task_meta "$case_dir" "$id" scout ''
  # A scout's deliverable is its report, and teardown also enforces the shared
  # captain-call completion gate; satisfy both the way a real scout does.
  mkdir -p "$(home_of "$case_dir")/data/$id"
  printf 'findings\n' > "$(home_of "$case_dir")/data/$id/report.md"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$(home_of "$case_dir")" \
    PATH="$case_dir/fakebin:$PATH" \
    "$ROOT/bin/fm-captain-hold.sh" complete "$id" --none >/dev/null \
    || fail "could not record the scout's completed captain-call inventory"

  out=$(run_teardown "$case_dir" "$id") || fail "teardown failed: $out"
  [ "$(row_state "$case_dir" "$id")" = "done" ] \
    || fail "teardown reported success with the scout item still $(row_state "$case_dir" "$id")"
  assert_grep "data/$id/report.md" "$(backlog_of "$case_dir")" \
    "a closed scout item did not record its report"
  pass "completion closes a scout item against its report"
}

test_completion_fails_loudly_and_records_the_close_it_still_owes() {
  local case_dir id out rc=0
  id=atomic-close-b7
  case_dir=$(make_home close-fails)
  add_item "$case_dir" "$id"
  start_item "$case_dir" "$id"
  write_task_meta "$case_dir" "$id" ship local-only
  break_verb "$case_dir" "done"

  out=$(run_teardown "$case_dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "teardown reported success while its item was still In flight"
  assert_contains "$out" "could not be closed" \
    "teardown failed without explaining the unclosed backlog item"
  assert_present "$(home_of "$case_dir")/state/$id.backlog-close" \
    "teardown lost the close it still owes"
  pass "completion refuses to report success while its item is still open, and records what it owes"
}

# --- same-home recovery -----------------------------------------------------

test_recovery_marks_an_owned_record_in_flight() {
  local case_dir id out
  id=atomic-heal-b8
  case_dir=$(make_home heal-queued)
  add_item "$case_dir" "$id"
  write_task_meta "$case_dir" "$id" ship no-mistakes

  out=$(run_bootstrap "$case_dir")
  [ "$(row_state "$case_dir" "$id")" = in_flight ] \
    || fail "session start left an owned record's item at $(row_state "$case_dir" "$id"): $out"
  pass "session start marks an item In flight when this home already owns a worker for it"
}

test_recovery_replays_a_close_an_interrupted_cleanup_left_open() {
  local case_dir id out
  id=atomic-heal-b9
  case_dir=$(make_home heal-pending-close)
  add_item "$case_dir" "$id"
  start_item "$case_dir" "$id"
  printf 'id=%s\ndata=%s\narg=--pr\narg=https://github.com/example/repo/pull/11\n' \
    "$id" "$(home_of "$case_dir")/data" \
    > "$(home_of "$case_dir")/state/$id.backlog-close"

  out=$(run_bootstrap "$case_dir")
  [ "$(row_state "$case_dir" "$id")" = "done" ] \
    || fail "session start left an interrupted cleanup's item at $(row_state "$case_dir" "$id"): $out"
  assert_grep 'https://github.com/example/repo/pull/11' "$(backlog_of "$case_dir")" \
    "the replayed close dropped the completion link the cleanup had recorded"
  assert_absent "$(home_of "$case_dir")/state/$id.backlog-close" \
    "a replayed close left its record behind"
  pass "session start finishes a close an interrupted cleanup recorded but never landed"
}

test_recovery_preserves_a_close_when_the_backlog_cannot_be_read() {
  local case_dir id out
  id=atomic-heal-read-error-b10
  case_dir=$(make_home heal-read-error)
  add_item "$case_dir" "$id"
  start_item "$case_dir" "$id"
  printf 'id=%s\ndata=%s\narg=--note\narg=local main\n' \
    "$id" "$(home_of "$case_dir")/data" \
    > "$(home_of "$case_dir")/state/$id.backlog-close"
  break_verb "$case_dir" show

  out=$(run_bootstrap "$case_dir")
  assert_present "$(home_of "$case_dir")/state/$id.backlog-close" \
    "a transient backlog read failure discarded the pending close"
  rm -f "$case_dir/fakebin/tasks-axi"
  [ "$(row_state "$case_dir" "$id")" = in_flight ] \
    || fail "a failed recovery changed the backlog row: $out"

  out=$(run_bootstrap "$case_dir")
  [ "$(row_state "$case_dir" "$id")" = "done" ] \
    || fail "the preserved close was not retried after the read recovered: $out"
  assert_absent "$(home_of "$case_dir")/state/$id.backlog-close" \
    "a successfully retried close left its marker behind"
  pass "session start preserves a pending close across a transient backlog read failure"
}

test_recovery_finishes_a_close_for_the_same_meta_incarnation() {
  local case_dir id out
  id=atomic-heal-same-incarnation-b11
  case_dir=$(make_home heal-same-incarnation)
  add_item "$case_dir" "$id"
  start_item "$case_dir" "$id"
  write_task_meta "$case_dir" "$id" ship no-mistakes "spawn_gen=spawn-one"
  printf 'id=%s\ndata=%s\nspawn_gen=spawn-one\narg=--note\narg=local main\n' \
    "$id" "$(home_of "$case_dir")/data" \
    > "$(home_of "$case_dir")/state/$id.backlog-close"

  out=$(run_bootstrap "$case_dir")
  [ "$(row_state "$case_dir" "$id")" = "done" ] \
    || fail "session start did not close the interrupted incarnation: $out"
  assert_absent "$(home_of "$case_dir")/state/$id.meta" \
    "session start retained the interrupted incarnation's meta"
  assert_absent "$(home_of "$case_dir")/state/$id.backlog-close" \
    "session start retained the completed incarnation's close marker"
  pass "session start finishes a close for the matching meta incarnation"
}

test_recovery_preserves_both_records_when_meta_removal_fails() {
  local case_dir id meta out
  id=atomic-heal-remove-failure-b12
  case_dir=$(make_home heal-remove-failure)
  add_item "$case_dir" "$id"
  start_item "$case_dir" "$id"
  meta="$(home_of "$case_dir")/state/$id.meta"
  write_task_meta "$case_dir" "$id" ship no-mistakes "spawn_gen=spawn-one"
  printf 'id=%s\ndata=%s\nspawn_gen=spawn-one\narg=--note\narg=local main\n' \
    "$id" "$(home_of "$case_dir")/data" \
    > "$(home_of "$case_dir")/state/$id.backlog-close"
  break_meta_removal "$case_dir" "$meta"

  out=$(run_bootstrap "$case_dir")
  assert_contains "$out" "could not remove the interrupted task record" \
    "session start did not surface the record-removal failure"
  assert_present "$meta" "failed recovery removed the task record"
  assert_present "$(home_of "$case_dir")/state/$id.backlog-close" \
    "failed recovery discarded the pending close"
  [ "$(row_state "$case_dir" "$id")" = in_flight ] \
    || fail "failed recovery closed the backlog before removing meta"

  rm -f "$case_dir/fakebin/rm"
  out=$(run_bootstrap "$case_dir")
  [ "$(row_state "$case_dir" "$id")" = "done" ] \
    || fail "recovery did not retry after meta removal recovered: $out"
  assert_absent "$meta" "successful retry retained the task record"
  assert_absent "$(home_of "$case_dir")/state/$id.backlog-close" \
    "successful retry retained the pending close"
  pass "recovery preserves both records when meta removal fails"
}

test_recovery_drops_a_close_for_a_newer_meta_incarnation() {
  local case_dir id out
  id=atomic-heal-new-incarnation-b12
  case_dir=$(make_home heal-new-incarnation)
  add_item "$case_dir" "$id"
  start_item "$case_dir" "$id"
  write_task_meta "$case_dir" "$id" ship no-mistakes "spawn_gen=spawn-two"
  printf 'id=%s\ndata=%s\nspawn_gen=spawn-one\narg=--note\narg=local main\n' \
    "$id" "$(home_of "$case_dir")/data" \
    > "$(home_of "$case_dir")/state/$id.backlog-close"

  out=$(run_bootstrap "$case_dir")
  [ "$(row_state "$case_dir" "$id")" = in_flight ] \
    || fail "session start closed the newer task incarnation: $out"
  assert_present "$(home_of "$case_dir")/state/$id.meta" \
    "session start removed the newer task incarnation's meta"
  assert_absent "$(home_of "$case_dir")/state/$id.backlog-close" \
    "a stale recorded close was left to fire on a later restart"
  pass "session start drops a close recorded for an older meta incarnation"
}

test_recovery_drops_a_legacy_close_when_meta_exists() {
  local case_dir id out
  id=atomic-heal-legacy-close-b13
  case_dir=$(make_home heal-legacy-close)
  add_item "$case_dir" "$id"
  start_item "$case_dir" "$id"
  write_task_meta "$case_dir" "$id" ship no-mistakes "spawn_gen=spawn-two"
  printf 'id=%s\ndata=%s\narg=--note\narg=local main\n' \
    "$id" "$(home_of "$case_dir")/data" \
    > "$(home_of "$case_dir")/state/$id.backlog-close"

  out=$(run_bootstrap "$case_dir")
  [ "$(row_state "$case_dir" "$id")" = in_flight ] \
    || fail "session start guessed that a legacy close belonged to the current meta: $out"
  assert_present "$(home_of "$case_dir")/state/$id.meta" \
    "session start removed meta for an unversioned legacy close"
  assert_absent "$(home_of "$case_dir")/state/$id.backlog-close" \
    "session start retained a legacy close that could not be matched safely"
  pass "session start treats an unversioned close as stale when meta exists"
}

test_recovery_leaves_a_captain_held_item_alone() {
  local case_dir id out
  id=atomic-heal-b11
  case_dir=$(make_home heal-held)
  add_item "$case_dir" "$id"
  tasks-axi hold "$id" --reason "captain decision pending" --kind captain \
    --file "$(backlog_of "$case_dir")" >/dev/null
  write_task_meta "$case_dir" "$id" ship no-mistakes

  out=$(run_bootstrap "$case_dir")
  [ "$(row_state "$case_dir" "$id")" = queued ] \
    || fail "session start moved a captain-held item to $(row_state "$case_dir" "$id"): $out"
  pass "session start leaves a captain-held item where the captain put it"
}

# --- backend selection and secondmate scope ---------------------------------

test_manual_backend_home_dispatches_and_completes_without_touching_the_backlog() {
  local case_dir id out
  id=atomic-manual-b12
  case_dir=$(make_home manual-backend "$id")
  printf '%s\n' manual > "$(home_of "$case_dir")/config/backlog-backend"
  # Deliberately no backlog item: on a manual home the operator owns the file,
  # so neither half of the lifecycle may hard-fail over its contents.
  out=$(run_ship_spawn "$case_dir" "$id") || fail "manual-backend spawn failed: $out"
  assert_contains "$out" "spawned $id" "manual-backend spawn did not report success"

  out=$(run_teardown "$case_dir" "$id") || fail "manual-backend teardown failed: $out"
  assert_contains "$out" "Update data/backlog.md" \
    "manual-backend teardown did not leave the backlog edit to the operator"
  assert_absent "$(home_of "$case_dir")/state/$id.backlog-close" \
    "manual-backend teardown recorded a close it never owed"
  pass "a manual-backlog home dispatches and completes without a hard failure"
}

test_a_secondmate_home_keeps_its_own_books() {
  local case_dir id out
  id=atomic-mate-b13
  case_dir=$(make_home mate-own-books "$id")
  # The mate's home is a firstmate home in its own right; the invariant is
  # single-host, so its own dispatch and completion keep its own two records
  # paired with no parent involved.
  printf '%s\n' mate-h1 > "$(home_of "$case_dir")/.fm-secondmate-home"
  add_item "$case_dir" "$id"

  out=$(run_ship_spawn "$case_dir" "$id") || fail "mate-home spawn failed: $out"
  [ "$(row_state "$case_dir" "$id")" = in_flight ] \
    || fail "a mate's own dispatch left its item at $(row_state "$case_dir" "$id")"

  rm -f "$(home_of "$case_dir")/state/$id.meta"
  write_task_meta "$case_dir" "$id" ship local-only
  out=$(run_teardown "$case_dir" "$id") || fail "mate-home teardown failed: $out"
  [ "$(row_state "$case_dir" "$id")" = "done" ] \
    || fail "a mate's own completion left its item at $(row_state "$case_dir" "$id")"
  pass "a secondmate home keeps its own books paired through dispatch and completion"
}

test_a_persistent_secondmate_is_never_a_backlog_item() {
  local case_dir id out mate
  id=atomic-mate-b14
  case_dir=$(make_home mate-not-an-item)
  mate="$case_dir/mate-home"
  mkdir -p "$mate/bin" "$mate/data"
  printf '# Firstmate\n' > "$mate/AGENTS.md"
  printf '%s\n' "$id" > "$mate/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$mate/data/charter.md"

  # No backlog item exists for the mate, and none should be required: agents are
  # not work items. The dispatch must succeed anyway.
  out=$(run_spawn "$case_dir" "$id" "$mate" --secondmate) \
    || fail "secondmate spawn failed: $out"
  assert_contains "$out" "spawned $id" "secondmate spawn did not report success"
  assert_present "$(home_of "$case_dir")/state/$id.meta" "secondmate spawn published no record"
  pass "dispatching a persistent secondmate needs no backlog item"
}

test_dispatch_moves_the_item_in_flight_in_the_same_run
test_dispatch_refuses_an_id_this_home_has_no_item_for
test_dispatch_refuses_a_closed_item
test_dispatch_leaves_no_record_when_the_transition_fails
test_dispatch_rolls_back_before_a_failed_launch_delivery
test_dispatch_does_not_resurrect_a_row_closed_after_preflight
test_dispatch_fails_when_its_row_vanishes_after_preflight
test_completion_closes_a_local_only_ship_before_reporting_success
test_completion_closes_a_scout_with_its_report
test_completion_fails_loudly_and_records_the_close_it_still_owes
test_recovery_marks_an_owned_record_in_flight
test_recovery_replays_a_close_an_interrupted_cleanup_left_open
test_recovery_preserves_a_close_when_the_backlog_cannot_be_read
test_recovery_finishes_a_close_for_the_same_meta_incarnation
test_recovery_preserves_both_records_when_meta_removal_fails
test_recovery_drops_a_close_for_a_newer_meta_incarnation
test_recovery_drops_a_legacy_close_when_meta_exists
test_recovery_leaves_a_captain_held_item_alone
test_manual_backend_home_dispatches_and_completes_without_touching_the_backlog
test_a_secondmate_home_keeps_its_own_books
test_a_persistent_secondmate_is_never_a_backlog_item
