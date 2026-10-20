#!/usr/bin/env bash
# Tests for the copilot-pod launcher against a stubbed `docker` (no daemon needed). See "Testing" in
# docs/docker-sidecar.md. Usage: tests/stubbed-docker.sh [test-name ...]   (default: all tests + mutants)
# Everything the daemon would do (rootless sidecar, TLS, real volumes, real signals through Docker) is
# NOT covered here; use the real-Docker checklist in the docs for that.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
BIN="$T/bin"; mkdir -p "$BIN"
LAUNCHER="${LAUNCHER:-$ROOT/copilot-pod}"

# The stub logs every call ("$*") and is steered by STUB_* variables:
#   STUB_POD_EXIT=N       exit code of the pod (default 0)
#   STUB_POD_SLEEP=N      the pod runs N seconds or until `docker stop <pod>` (then exits 143)
#   STUB_POD_CREATE_DELAY=N  the pod is "created but not started" for N seconds first; like real Docker,
#                         `docker stop` then succeeds and does nothing (measured: rc 0, state stays created)
#   STUB_NAME_CONFLICT=1  `docker run -d` fails like a taken container name
#   STUB_SIDECAR_DEAD=1   sidecar never becomes ready and is reported as exited, with a rootlesskit log
#   STUB_READY_AFTER=N    sidecar becomes ready after N failed `exec` probes (1000 = never)
#   STUB_VOLUME_EXISTS=1  `volume inspect` succeeds (cache reuse)
#   STUB_RM_INUSE / STUB_RM_MISSING   space-separated volume names for which `volume rm` fails
#                         with the real Docker 28 wording ("volume is in use" / "no such volume")
#   STUB_NETRM_SLEEP=N    `network rm` takes N seconds (widens the cleanup window for signals)
#   STUB_UID / STUB_GID   what `id -u` / `id -g` report (default 1000, so the real host uid never matters)
#   STUB_UNAME=Darwin     what `uname -s` reports (default Linux)
#   STUB_POD_LINGER=N     after `docker stop` the container is gone ("No such container") but the client
#                         keeps running N more seconds, like a client still writing output; a second signal
#                         to it is recorded in client-killed (the real client then exits 1 and cuts the output)
#   STUB_POD_DRAIN=N      the container is already gone when the client starts (the pod ended by itself, --rm) but
#                         the client keeps writing for N seconds; like Docker's client it survives two signals
#                         and exits 1 on the third (client-killed)
#   STUB_DERIVED_EXISTS=1 the derived sidecar image already exists; STUB_BUILD_FAIL=1 `docker build` fails
cat >"$BIN/docker" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
case "$1" in
  info) exit 0 ;;
  image)
    if [[ "$*" == *copilot-pod-dind* ]]; then
      { [ -n "${STUB_DERIVED_EXISTS:-}" ] || [ -e "$STUB_DIR/built" ]; } && echo derivedid; exit 0
    fi
    [ "$2" = ls ] && echo abc123; exit 0 ;;
  build) cat > "$STUB_DIR/dockerfile"; : > "$STUB_DIR/built"; exit "${STUB_BUILD_FAIL:-0}" ;;
  network) [ "$2" = rm ] && sleep "${STUB_NETRM_SLEEP:-0}"; exit 0 ;;
  volume)
    case "$2" in
      inspect) [ -n "${STUB_VOLUME_EXISTS:-}" ]; exit ;;
      rm)
        if [[ " ${STUB_RM_INUSE:-} " == *" $3 "* ]]; then
          echo "Error response from daemon: remove $3: volume is in use - [7899c51c54fa]" >&2; exit 1
        elif [[ " ${STUB_RM_MISSING:-} " == *" $3 "* ]]; then
          echo "Error response from daemon: get $3: no such volume" >&2; exit 1
        fi ;;
    esac
    exit 0 ;;
  run)
    if [ "$2" = -d ]; then
      if [ -n "${STUB_NAME_CONFLICT:-}" ]; then
        echo 'docker: Error response from daemon: Conflict. The container name is already in use.' >&2; exit 125
      fi
      : > "$STUB_DIR/sidecar"; echo sidecarid; exit 0
    fi
    if [ -n "${STUB_POD_SLEEP:-}${STUB_POD_DRAIN:-}" ]; then
      : > "$STUB_DIR/pod-created"; sleep "${STUB_POD_CREATE_DELAY:-0}"
      sleep "${STUB_POD_SLEEP:-$STUB_POD_DRAIN}" & s=$!
      term() {
        if [ -n "${STUB_POD_DRAIN:-}" ]; then
          echo x >> "$STUB_DIR/client-signals"
          [ "$(wc -l < "$STUB_DIR/client-signals")" -ge 3 ] || return 0
          : > "$STUB_DIR/client-killed"; exit 1
        fi
        if [ -e "$STUB_DIR/pod-stopped" ]; then : > "$STUB_DIR/client-killed"; exit 1; fi
        kill $s 2>/dev/null
        if [ -n "${STUB_POD_LINGER:-}" ]; then : > "$STUB_DIR/pod-stopped"; sleep "$STUB_POD_LINGER" & wait $!; fi
        exit 143
      }
      trap term TERM
      echo $$ > "$STUB_DIR/pod.pid"
      echo started > "$STUB_DIR/pod-running"
      [ -z "${STUB_POD_DRAIN:-}" ] || : > "$STUB_DIR/pod-stopped"
      while kill -0 $s 2>/dev/null; do wait $s 2>/dev/null; done
    fi
    exit "${STUB_POD_EXIT:-0}" ;;
  exec)
    [[ "$*" == *"system df"* ]] && { echo 'Images|3|1.2GB'; exit 0; }
    [ -z "${STUB_SIDECAR_DEAD:-}" ] || exit 1
    n="$(cat "$STUB_DIR/probes" 2>/dev/null || echo 0)"; echo $((n + 1)) > "$STUB_DIR/probes"
    [ "$n" -ge "${STUB_READY_AFTER:-0}" ]; exit ;;
  inspect) [ -n "${STUB_SIDECAR_DEAD:-}" ] && echo false || echo true; exit 0 ;;
  logs) [ -z "${STUB_SIDECAR_DEAD:-}" ] || echo '[rootlesskit:parent] error: fork/exec /proc/self/exe: operation not permitted'; exit 0 ;;
  ps) [ ! -e "$STUB_DIR/sidecar" ] || echo sidecarid; exit 0 ;;
  stop)
    # Stopping the pod ends the stub pod; its own exit code (143) is what the launcher must report.
    if [[ "$*" == *copilot-pod-run-* ]]; then
      if [ -e "$STUB_DIR/pod-stopped" ]; then echo 'Error response from daemon: No such container' >&2; exit 1; fi
      if [ ! -f "$STUB_DIR/pod.pid" ]; then
        [ -f "$STUB_DIR/pod-created" ] && exit 0   # created, not started: succeeds and does nothing
        echo 'Error response from daemon: No such container' >&2; exit 1
      fi
      kill -TERM "$(cat "$STUB_DIR/pod.pid")" 2>/dev/null
    fi
    exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$BIN/docker"
cat >"$BIN/id" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in -u) echo "${STUB_UID:-1000}" ;; -g) echo "${STUB_GID:-1000}" ;; *) exec /usr/bin/id "$@" ;; esac
STUB
cat >"$BIN/uname" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in -s) echo "${STUB_UNAME:-Linux}" ;; *) exec /usr/bin/uname "$@" ;; esac
STUB
chmod +x "$BIN/id" "$BIN/uname"

# ---- harness -------------------------------------------------------------------------------------------
fail() { echo "    FAIL: $*" >&2; [ -f "$CASE/out" ] && sed 's/^/    out| /' "$CASE/out" >&2; [ -f "$CASE/err" ] && sed 's/^/    err| /' "$CASE/err" >&2; [ -f "$STUB_LOG" ] && sed 's/^/    log| /' "$STUB_LOG" >&2; exit 1; }
setup_case() {
  CASE="$(mktemp -d "$T/case.XXXXXX")"
  PROJ="$CASE/my proj"; H="$CASE/home dir"          # spaces on purpose
  STATE="$H/state/copilot-pod/caches"
  mkdir -p "$PROJ" "$H"
  export STUB_LOG="$CASE/docker.log" STUB_DIR="$CASE/stub"; mkdir -p "$STUB_DIR"; : > "$STUB_LOG"
  HASH="$(cd "$PROJ" && { pwd -P; echo 1000:1000; } | sha256sum | cut -c1-16)"   # the stub reports uid and gid 1000
}
launch_env() { cd "$PROJ" && HOME="$H" XDG_STATE_HOME="$H/state" COPILOT_POD_NO_UPDATE=1 PATH="$BIN:$PATH" "$@"; }
launch() {   # launch <env VAR=...>... -- args   (foreground; sets RC)
  local envs=(); while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  RC=0; (launch_env env ${envs[@]+"${envs[@]}"} timeout 60 "$LAUNCHER" "$@" </dev/null >"$CASE/out" 2>"$CASE/err") || RC=$?
}
launch_bg() { # same, background; sets LPID
  local envs=(); while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  # Job control (set -m) gives the background launcher default signal dispositions; without it a non-interactive
  # shell starts async commands with SIGINT ignored, and bash cannot trap a signal that was ignored on entry.
  set -m
  (launch_env exec env ${envs[@]+"${envs[@]}"} "$LAUNCHER" "$@" </dev/null >"$CASE/out" 2>"$CASE/err") &
  LPID=$!
  set +m
  ( sleep 45; kill -9 "$LPID" 2>/dev/null ) & WD=$!
}
finish_bg() { RC=0; wait "$LPID" || RC=$?; kill "$WD" 2>/dev/null; wait "$WD" 2>/dev/null; return 0; }
logged()    { grep -qE -- "$1" "$STUB_LOG" || fail "expected docker call matching: $1"; }
not_logged(){ ! grep -qE -- "$1" "$STUB_LOG" || fail "unexpected docker call matching: $1"; }
in_out()    { cat "$CASE/out" "$CASE/err" | grep -qE -- "$1" || fail "expected output matching: $1"; }
rc_is()     { [ "$RC" = "$1" ] || fail "exit code $RC, expected $1"; }
order() {    # order <regex>... : first match of each appears in this order
  local last=0 n re; for re in "$@"; do
    n="$(grep -nE -- "$re" "$STUB_LOG" | head -n1 | cut -d: -f1)"; [ -n "$n" ] || fail "missing docker call: $re"
    [ "$n" -gt "$last" ] || fail "docker call out of order: $re"; last=$n; done
}
wait_for() { local i; for i in $(seq 1 100); do [ -e "$1" ] && return 0; sleep 0.1; done; fail "timed out waiting for $1"; }

# ---- tests ---------------------------------------------------------------------------------------------
test_plain_exec() {   # without DOCKER=1 the launcher only execs docker run (invariant 7)
  setup_case; launch STUB_POD_EXIT=3 -- true
  rc_is 3
  [ "$(grep -c . "$STUB_LOG")" = 3 ] || fail "expected info, image ls and one run"
  not_logged 'network|volume|--init|--privileged'
  logged '^run --rm .*copilot-pod true$'
}
test_sequence() {   # DOCKER=1: command order, run-id consistency, exit code, cleanup
  setup_case; launch DOCKER=1 STUB_POD_EXIT=7 -- true
  rc_is 7
  order '^network create copilot-pod-net-' '^volume create copilot-pod-certs-' '^run -d --privileged --init --name copilot-pod-dind-' \
        '^exec -e DOCKER_HOST=tcp://localhost:2376' '^run --rm .*--name copilot-pod-run-' \
        '^rm -f copilot-pod-run-' '^ps -aq --filter label=copilot-pod.run=' '^stop -t 10 sidecarid' '^rm -f -v sidecarid' \
        '^network rm copilot-pod-net-' '^volume rm copilot-pod-certs-'
  logged '^run --rm .* --init '
  logged '^run --rm .*--network=copilot-pod-net-.*DOCKER_HOST=tcp://dind:2376.*DOCKER_TLS_VERIFY=1'
  logged '^run --rm .*--cap-drop=ALL'
  local net rmnet; net="$(sed -n 's/^network create //p' "$STUB_LOG")"; rmnet="$(sed -n 's/^network rm //p' "$STUB_LOG")"
  [ -n "$net" ] && [ "$net" = "$rmnet" ] || fail "cleanup removed '$rmnet', run created '$net'"
  [ "$(sed -n 's/.*label=copilot-pod.run=//p' "$STUB_LOG" | head -n1)" = "${net#copilot-pod-net-}" ] || fail "run id differs between resources"
  not_logged 'volume rm copilot-pod-docker-'
}
test_option_validation() {   # DOCKER=0 etc. must never start a sidecar
  local c; for c in "DOCKER=0" "DOCKER=true" "DOCKER=1 DOCKER_CACHE=false" "DOCKER_CACHE=1" "DOCKER=1 NET=none"; do
    setup_case; launch $c -- true
    rc_is 1; not_logged '^(run|network|volume)'
  done
}
test_cache_new() {   # new cache volume, fixed sidecar name, stamp
  setup_case; launch DOCKER=1 DOCKER_CACHE=1 -- true
  rc_is 0
  in_out "created new copilot-pod-docker-$HASH"
  logged "^run -d --privileged --init --name copilot-pod-dind-cache-$HASH "
  logged " -v copilot-pod-docker-$HASH:/home/rootless/.local/share/docker "
  [ -f "$STATE/copilot-pod-docker-$HASH" ] || fail "stamp file missing"
  not_logged 'volume rm copilot-pod-docker-'
}
test_cache_reuse() {
  setup_case; launch DOCKER=1 DOCKER_CACHE=1 STUB_VOLUME_EXISTS=1 -- true
  rc_is 0; in_out "reusing copilot-pod-docker-$HASH \(3 images, 1.2GB\)"
}
test_cache_conflict() {   # name already taken: refuse, point at the leftover, touch nothing of the other session
  setup_case; launch DOCKER=1 DOCKER_CACHE=1 STUB_NAME_CONFLICT=1 -- true
  rc_is 1; in_out "docker rm -f copilot-pod-dind-cache-$HASH"
  not_logged '^run --rm'; not_logged '^(stop|rm -f -v)'
  logged '^network rm '
}
test_host_uid() {   # Linux, uid other than 1000: derived sidecar image for that uid, built once, before the sidecar
  setup_case; launch DOCKER=1 STUB_UID=1001 STUB_GID=1002 -- true
  rc_is 0
  logged '^build -q -t copilot-pod-dind:uid1001-gid1002-[0-9a-f]{64} --build-arg BASE=docker:28-dind-rootless@sha256:[0-9a-f]{64} --build-arg U=1001 --build-arg G=1002 --build-arg SUB=100000 -$'
  logged '^run -d --privileged --init .* copilot-pod-dind:uid1001-gid1002-[0-9a-f]{64}$'
  order '^build ' '^network create' '^run -d'
  grep -q 'rootless:x:\$U:\$G:' "$STUB_DIR/dockerfile" || fail "Dockerfile does not renumber the rootless user"
  in_out 'Building Docker sidecar image for uid 1001'
  setup_case; launch DOCKER=1 STUB_UID=1001 STUB_GID=1002 STUB_DERIVED_EXISTS=1 -- true   # already built: reused
  rc_is 0; not_logged '^build '; logged '^run -d .* copilot-pod-dind:uid1001-gid1002-'
}
test_host_uid_subid_range() {   # the subordinate id range must not contain the host uid or gid (else dockerd cannot start)
  local c; for c in "1001 1002 100000" "100000 1001 100001" "1001 150000 150001" "165535 165536 165537" "200000 200000 200001"; do
    set -- $c; setup_case; launch DOCKER=1 STUB_UID=$1 STUB_GID=$2 -- true
    rc_is 0; logged " --build-arg U=$1 --build-arg G=$2 --build-arg SUB=$3 -\$"
  done
  grep -q 'rootless:\$SUB:65536' "$STUB_DIR/dockerfile" || fail "Dockerfile does not write the subordinate range"
  grep -q '/etc/subuid' "$STUB_DIR/dockerfile" && grep -q '/etc/subgid' "$STUB_DIR/dockerfile" || fail "range written to only one of subuid/subgid"
}
test_host_uid_skipped() {   # stock image: uid 1000, root, a non-Linux host, a user-set DIND_IMAGE
  local c; for c in "STUB_UID=1000" "STUB_UID=0" "STUB_UID=1001 STUB_UNAME=Darwin" "STUB_UID=1001 DIND_IMAGE=my/dind:1"; do
    setup_case; launch DOCKER=1 $c -- true
    rc_is 0; not_logged '^build '; not_logged 'copilot-pod-dind:'
  done
  logged '^run -d .* my/dind:1$'
}
test_host_uid_build_fails() {   # no sidecar without its image
  setup_case; launch DOCKER=1 STUB_UID=1001 STUB_BUILD_FAIL=1 -- true
  rc_is 1; in_out 'Could not build the Docker sidecar image for uid 1001'; not_logged '^run '
}
test_host_uid_cache() {   # the cache volume of the derived image is separate from the one owned by uid 1000
  setup_case; launch DOCKER=1 DOCKER_CACHE=1 STUB_UID=1001 -- true
  local h; h="$(cd "$PROJ" && { pwd -P; echo 1001:1000; } | sha256sum | cut -c1-16)"
  rc_is 0; in_out "created new copilot-pod-docker-$h"; logged "^run -d .*--name copilot-pod-dind-cache-$h "
  [ "$h" != "$HASH" ] || fail "uid not part of the hash"
  # same uid, other primary group (sg, newgrp): another derived image, so another volume
  setup_case; launch DOCKER=1 DOCKER_CACHE=1 STUB_UID=1001 STUB_GID=1002 -- true
  local h2; h2="$(cd "$PROJ" && { pwd -P; echo 1001:1002; } | sha256sum | cut -c1-16)"
  rc_is 0; in_out "created new copilot-pod-docker-$h2"; [ "$h2" != "$h" ] || fail "gid not part of the hash"
  # a user-set DIND_IMAGE keeps the stock image (uid 1000): same cache as on a uid 1000 host, not the derived one
  setup_case; launch DOCKER=1 DOCKER_CACHE=1 STUB_UID=1001 DIND_IMAGE=my/dind:1 -- true
  rc_is 0; in_out "created new copilot-pod-docker-$HASH"
}
test_prune() {   # old stamps pruned; young, in-use and foreign files kept; gone volumes lose only the stamp
  setup_case; mkdir -p "$STATE"
  local old=copilot-pod-docker-aaaaaaaaaaaaaaaa young=copilot-pod-docker-bbbbbbbbbbbbbbbb \
        inuse=copilot-pod-docker-cccccccccccccccc gone=copilot-pod-docker-dddddddddddddddd
  touch -d '3 days ago' "$STATE/$old" "$STATE/$inuse" "$STATE/$gone" "$STATE/not-a-cache" "$STATE/copilot-pod-docker-short"
  touch "$STATE/$young"
  launch DOCKER=1 DOCKER_CACHE=1 DOCKER_CACHE_MAX_AGE_DAYS=1 STUB_RM_INUSE="$inuse" STUB_RM_MISSING="$gone" -- true
  rc_is 0
  logged "^volume rm $old\$"; [ ! -e "$STATE/$old" ] || fail "old stamp not removed"
  in_out "Removed Docker cache $old"
  [ -e "$STATE/$young" ] || fail "young stamp removed"; not_logged "volume rm $young"
  [ -e "$STATE/$inuse" ] || fail "in-use stamp removed"
  [ ! -e "$STATE/$gone" ] || fail "stamp of an already deleted volume kept"
  ! grep -q "Removed Docker cache $gone" "$CASE/err" || fail "reported a removal that did not happen"
  not_logged 'volume rm (not-a-cache|copilot-pod-docker-short)'; [ -e "$STATE/not-a-cache" ] || fail "foreign file removed"
}
test_prune_settings() {   # 0 disables, garbage is rejected before anything starts
  setup_case; mkdir -p "$STATE"; touch -d '400 days ago' "$STATE/copilot-pod-docker-aaaaaaaaaaaaaaaa"
  launch DOCKER=1 DOCKER_CACHE=1 DOCKER_CACHE_MAX_AGE_DAYS=0 -- true
  rc_is 0; not_logged 'volume rm copilot-pod-docker-'
  setup_case; launch DOCKER=1 DOCKER_CACHE=1 DOCKER_CACHE_MAX_AGE_DAYS=abc -- true
  rc_is 1; in_out 'must be a number of days'; not_logged '^run -d'
}
test_sidecar_dead() {   # exited sidecar: reported immediately with the userns hint, then cleaned up
  setup_case; local s=$SECONDS; launch DOCKER=1 STUB_SIDECAR_DEAD=1 -- true
  rc_is 1; [ $((SECONDS - s)) -lt 10 ] || fail "took the full readiness timeout"
  in_out 'exited during startup'; in_out 'unprivileged user namespaces'
  not_logged '^run --rm'; order '^rm -f -v sidecarid' '^network rm' '^volume rm copilot-pod-certs-'
}
test_term_startup() {   # SIGTERM while the sidecar is starting: 143 and everything removed
  setup_case; launch_bg DOCKER=1 STUB_READY_AFTER=1000 -- true
  wait_for "$STUB_DIR/sidecar"; sleep 1; kill -TERM "$LPID"; finish_bg
  rc_is 143; not_logged '^run --rm'; order '^rm -f -v sidecarid' '^network rm' '^volume rm copilot-pod-certs-'
}
test_double_term_startup() {   # a second SIGTERM during cleanup must not cut it short
  setup_case; launch_bg DOCKER=1 STUB_READY_AFTER=1000 STUB_NETRM_SLEEP=3 -- true
  wait_for "$STUB_DIR/sidecar"; sleep 1; kill -TERM "$LPID"
  wait_for_log() { local i; for i in $(seq 1 100); do grep -q '^network rm' "$STUB_LOG" && return 0; sleep 0.1; done; fail "cleanup never started"; }
  wait_for_log; sleep 0.5; kill -TERM "$LPID" 2>/dev/null; finish_bg
  logged '^volume rm copilot-pod-certs-'
}
test_term_running() {   # SIGTERM while the pod runs: pod is stopped first, its status (143) is reported, then cleanup
  setup_case; launch_bg DOCKER=1 STUB_POD_SLEEP=60 -- sleep 60
  wait_for "$STUB_DIR/pod-running"; kill -TERM "$LPID"; finish_bg
  rc_is 143; order '^stop -t 10 copilot-pod-run-' '^rm -f copilot-pod-run-' '^rm -f -v sidecarid' '^network rm' '^volume rm copilot-pod-certs-'
}
test_int_hup_startup() {   # INT/HUP while the sidecar starts: 130/129, everything removed
  local sig code; for sig in INT:130 HUP:129; do code=${sig#*:}; sig=${sig%:*}
    setup_case; launch_bg DOCKER=1 STUB_READY_AFTER=1000 -- true
    wait_for "$STUB_DIR/sidecar"; sleep 1; kill -"$sig" "$LPID"; finish_bg
    rc_is "$code"; not_logged '^run --rm'; order '^rm -f -v sidecarid' '^network rm' '^volume rm copilot-pod-certs-'
  done
}
test_int_hup_running() {   # INT/HUP while the pod runs: pod stopped first, then cleanup (same path as SIGTERM)
  local sig; for sig in INT HUP; do
    setup_case; launch_bg DOCKER=1 STUB_POD_SLEEP=60 -- sleep 60
    wait_for "$STUB_DIR/pod-running"; kill -"$sig" "$LPID"; finish_bg
    rc_is 143; order '^stop -t 10 copilot-pod-run-' '^rm -f -v sidecarid' '^network rm' '^volume rm copilot-pod-certs-'
  done
}
test_stop_signal() {   # only the default (interactive) shell is stopped with SIGHUP; see the comment in the launcher
  setup_case; launch DOCKER=1 --
  rc_is 0; logged '^run --rm .*--init --stop-signal=SIGHUP '
  setup_case; launch DOCKER=1 -- bash
  rc_is 0; logged '^run --rm .*--init --stop-signal=SIGHUP .* copilot-pod bash$'
  local c; for c in "true" "bash -c true" "bash script.sh" "copilot --version"; do
    setup_case; launch DOCKER=1 -- $c
    rc_is 0; not_logged 'stop-signal'
  done
  setup_case; launch -- ; rc_is 0; not_logged 'stop-signal'   # plain path unchanged (invariant 7)
}
test_term_during_pod_creation() {   # a stop that hits the created-but-not-started pod is a no-op in Docker: retry it
  setup_case; launch_bg DOCKER=1 STUB_POD_SLEEP=8 STUB_POD_CREATE_DELAY=3 -- sleep 8
  wait_for "$STUB_DIR/pod-created"; kill -TERM "$LPID"; finish_bg
  rc_is 143; order '^stop -t 10 copilot-pod-run-' '^rm -f -v sidecarid' '^network rm'
}
test_stop_while_client_drains() {   # the container is gone but its client is still finishing: leave it alone
  setup_case; launch_bg DOCKER=1 STUB_POD_SLEEP=60 STUB_POD_LINGER=3 -- sleep 60
  wait_for "$STUB_DIR/pod-running"; kill -TERM "$LPID"; finish_bg
  rc_is 143; [ ! -e "$STUB_DIR/client-killed" ] || fail "the client was signalled again while it was finishing its output"
  [ "$(grep -c '^stop -t 10 copilot-pod-run-' "$STUB_LOG")" -le 2 ] || fail "stop was retried after the container was gone"
  order '^stop -t 10 copilot-pod-run-' '^rm -f -v sidecarid' '^network rm'
}
test_stop_after_natural_exit() {   # the pod ended by itself and its client is still writing: a stop request must not cut it
  setup_case; launch_bg DOCKER=1 STUB_POD_DRAIN=4 -- true
  wait_for "$STUB_DIR/pod-running"; kill -TERM "$LPID"; finish_bg
  rc_is 0; [ ! -e "$STUB_DIR/client-killed" ] || fail "the client was signalled until it gave up while it was still writing"
  [ "$(wc -l < "$STUB_DIR/client-signals")" -le 1 ] || fail "the client was signalled more than once"
  order '^stop -t 10 copilot-pod-run-' '^rm -f -v sidecarid' '^network rm'
}
test_term_before_pod_pid() {   # a stop request in the gap before POD_PID is known must not be lost
  setup_case
  # The gap is microseconds wide, so inject the signal into a copy of the launcher right before the pod starts.
  local src hook; src="$(cat "$LAUNCHER"; echo x)"; src="${src%x}"
  hook=$'"${RUN_CMD[@]}" <&0 &\n'
  [[ "$src" == *"$hook"* ]] || fail "launcher layout changed: pod start line not found"
  printf '%s%s%s%s' "${src%%"$hook"*}" 'kill -TERM $$'$'\n' "$hook" "${src#*"$hook"}" > "$CASE/injected"; chmod +x "$CASE/injected"
  LAUNCHER="$CASE/injected" launch_bg DOCKER=1 STUB_POD_SLEEP=8 -- sleep 8; finish_bg
  rc_is 143; order '^stop -t 10 copilot-pod-run-' '^rm -f -v sidecarid' '^network rm'
}

# ---- mutants: each must make its test fail, proving the test discriminates -----------------------------
mutate() {   # mutate <test> <old> <new>   (literal replacement in a copy of the launcher)
  local test="$1" old="$2" new="$3" src; src="$(cat "$ROOT/copilot-pod"; echo x)"; src="${src%x}"
  declare -F "$test" >/dev/null || { echo "  ERROR  mutant names an unknown test: $test"; return 1; }
  [[ "$src" == *"$old"* ]] || { echo "  ERROR  mutant for $test does not apply: $old"; return 1; }
  printf '%s' "${src/"$old"/$new}" > "$T/mutant"; chmod +x "$T/mutant"
  if ( LAUNCHER="$T/mutant" "$0" --inner "$test" >/dev/null 2>&1 ); then
    echo "  SURVIVED  $test passes without: ${old%%$'\n'*}"; return 1
  fi
  echo "  killed    $test fails without: ${old%%$'\n'*}"
}
run_mutants() {
  local rc=0
  mutate test_sequence      $'  ${DOCKER:+--init} \\\n' '' || rc=1
  mutate test_sequence      'docker run -d --privileged --init \' 'docker run -d --privileged \' || rc=1
  mutate test_sequence      $'  docker network rm "$DIND_NET" >/dev/null 2>&1 || true\n' '' || rc=1
  mutate test_option_validation 'die "$_v must be 1 (or unset), not '"'"'${!_v}'"'"'."' 'true' || rc=1
  mutate test_cache_new     'DIND_NAME="copilot-pod-dind-cache-$_hash"' 'DIND_NAME="copilot-pod-dind-$RUN_ID"' || rc=1
  mutate test_host_uid_skipped '[ "$(id -u)" != 1000 ] && [ "$(id -u)" != 0 ]' '[ "$(id -u)" != 0 ]' || rc=1
  mutate test_host_uid_skipped ' && [ "$(id -u)" != 0 ]; then' '; then' || rc=1
  mutate test_host_uid_skipped '[ -z "$_dind_image_set" ] && ' '' || rc=1
  mutate test_host_uid_skipped '[ "$(uname -s)" = Linux ] && ' '' || rc=1
  mutate test_host_uid      'if [ -z "$(docker image ls -q "$DIND_IMAGE" 2>/dev/null)" ]; then' 'if true; then' || rc=1
  mutate test_host_uid_cache 'echo "${DIND_UID:-1000}:${DIND_GID:-1000}"' 'echo "$(id -u):$(id -g)"' || rc=1
  mutate test_host_uid_cache 'echo "${DIND_UID:-1000}:${DIND_GID:-1000}"' 'echo 1000:1000' || rc=1
  mutate test_host_uid_cache 'echo "${DIND_UID:-1000}:${DIND_GID:-1000}"' 'echo "${DIND_UID:-1000}:1000"' || rc=1
  mutate test_host_uid_subid_range '_sub=$(( _max < 100000 ? 100000 : _max + 1 ))' '_sub=100000' || rc=1
  mutate test_host_uid_subid_range '_max=$(( DIND_UID > DIND_GID ? DIND_UID : DIND_GID ))' '_max=$DIND_UID' || rc=1
  mutate test_host_uid_subid_range ' | tee /etc/subuid > /etc/subgid' ' > /etc/subuid' || rc=1
  mutate test_prune         '-mmin +$(( max_days * 1440 ))' '-mmin +0' || rc=1
  mutate test_prune         'elif grep -qi '"'"'no such volume'"'"' <<<"$out"; then' 'elif false; then' || rc=1
  mutate test_double_term_startup $'  trap \'\' INT TERM HUP\n' '' || rc=1
  mutate test_stop_signal   'STOP_FLAGS=(--stop-signal=SIGHUP)' 'STOP_FLAGS=()' || rc=1
  mutate test_stop_signal   '[ "$#" -eq 0 ] || {' 'true || {' || rc=1
  mutate test_stop_signal   '[ "$#" -eq 1 ] && [ "$1" = bash ]' '[ "$1" = bash ]' || rc=1
  mutate test_term_before_pod_pid $'  [ -z "$STOP_REQUESTED" ] || stop_pod\n' '' || rc=1
  mutate test_term_during_pod_creation $'  [ -z "$STOP_REQUESTED" ] || stop_pod\n' '' || rc=1
  mutate test_term_before_pod_pid $'  STOP_REQUESTED=1\n' '' || rc=1
  mutate test_stop_while_client_drains 'elif [ -n "$POD_SEEN" ]; then POD_GONE=1' 'elif false; then POD_GONE=1' || rc=1
  mutate test_stop_while_client_drains $'  [ -z "$POD_GONE" ] || return 0\n' '' || rc=1
  mutate test_stop_after_natural_exit '[ -n "$POD_PID" ] && [ -z "$POD_KILLED" ]; then POD_KILLED=1;' '[ -n "$POD_PID" ]; then' || rc=1
  mutate test_term_running  'trap stop_pod TERM INT HUP' 'trap "" TERM INT HUP' || rc=1
  mutate test_int_hup_running 'trap stop_pod TERM INT HUP' 'trap stop_pod TERM' || rc=1
  mutate test_int_hup_startup "trap 'exit 130' INT" "trap 'exit 1' INT" || rc=1
  mutate test_int_hup_startup "trap 'exit 129' HUP" "trap 'exit 1' HUP" || rc=1
  return $rc
}

# ---- main ----------------------------------------------------------------------------------------------
if [ "${1:-}" = --inner ]; then "$2"; exit $?; fi
# No mapfile (not in Bash 3.2) and no silent empty run: an empty list would skip the baseline and let every
# mutant count as killed.
tests=("$@"); [ ${#tests[@]} -gt 0 ] || tests=($(declare -F | awk '$3 ~ /^test_/ {print $3}'))
[ ${#tests[@]} -gt 0 ] || { echo "  ERROR     no tests found" >&2; exit 1; }
failed=0
for t in "${tests[@]}"; do
  if ( "$t" ); then echo "  ok        $t"; else echo "  FAILED    $t"; failed=1; fi
done
if [ $# -eq 0 ] && [ "$LAUNCHER" = "$ROOT/copilot-pod" ]; then echo "mutants:"; run_mutants || failed=1; fi
exit $failed
