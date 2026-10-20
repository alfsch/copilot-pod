#!/usr/bin/env bash
# Integration tests for copilot-pod against a REAL Docker daemon (the stub tests in stubbed-docker.sh need none).
# They check what an update of a tooling image (docker CLI, DIND sidecar, node base, yq) can break: that the
# pod image still has its tools, that the pinned sidecar image still honours the contract the launcher relies
# on, and that `DOCKER=1` sessions, the cache, TLS and signal handling work end to end.
#
# Needs: Docker, the image `copilot-pod` (./install.sh builds it) and, for the rootless sidecar, unprivileged
# user namespaces (on Ubuntu 24.04+: kernel.apparmor_restrict_unprivileged_userns=0). Network access to pull the
# inner test image (ITEST_INNER_IMAGES, tried in order). Only exit codes and results are asserted, never timings.
# The project folder must be visible to the Docker daemon: set ITEST_TMPDIR (default $TMPDIR or /tmp) to a
# directory the daemon can see if it runs in another mount namespace or a VM.
# Usage: tests/integration.sh        Exit status 1 if any check failed.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCHER="$ROOT/copilot-pod"
read -ra INNER_IMAGES <<<"${ITEST_INNER_IMAGES:-mirror.gcr.io/library/alpine:3 alpine:3}"

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); echo "ok   $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL $1"; }
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else fail "$d"; fi; }
section() { echo; echo "== $1"; }
indent() { sed 's/^/    | /'; }

command -v docker >/dev/null || { echo "docker is required" >&2; exit 2; }
docker info >/dev/null 2>&1 || { echo "the Docker daemon is not running" >&2; exit 2; }
[ -n "$(docker image ls -q copilot-pod 2>/dev/null)" ] || { echo "image 'copilot-pod' not found: run ./install.sh first" >&2; exit 2; }

BASE="${ITEST_TMPDIR:-${TMPDIR:-/tmp}}"; mkdir -p "$BASE"
WORK="$(mktemp -d "$BASE/copilot-pod-itest.XXXXXX")" || exit 2
PROJ="$WORK/project"; mkdir -p "$PROJ" "$WORK/home" "$WORK/state"
BG_PIDS=()
# What exists before the tests, to prove afterwards that nothing was left behind.
count() { docker "$@" 2>/dev/null | grep -c .; }
PRE_CONTAINERS="$(count ps -aq --filter label=copilot-pod.run)"
PRE_NETWORKS="$(count network ls -q --filter name=copilot-pod-net-)"
PRE_CERTS="$(count volume ls -q --filter name=copilot-pod-certs-)"

# The cache volume name is sha256 of the project path and the sidecar's uid:gid (see the launcher): 1000:1000 for
# the stock image, the host ids for the derived image used on Linux hosts with other uids.
HOST_UID="$(id -u)"; HOST_GID="$(id -g)"
if [ "$(uname -s)" = Linux ] && [ "$HOST_UID" != 1000 ] && [ "$HOST_UID" != 0 ]; then SIDECAR_IDS="$HOST_UID:$HOST_GID"; else SIDECAR_IDS=1000:1000; fi
CACHE_HASH="$(cd "$PROJ" && { pwd -P; echo "$SIDECAR_IDS"; } | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-16)"
CACHE_VOL="copilot-pod-docker-$CACHE_HASH"
PRUNE_VOL="copilot-pod-docker-0123456789abcdef"

cleanup() {
  local p
  for p in ${BG_PIDS[@]+"${BG_PIDS[@]}"}; do kill "$p" 2>/dev/null; done
  wait 2>/dev/null
  docker volume rm "$CACHE_VOL" "$PRUNE_VOL" >/dev/null 2>&1
  [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf -- "$WORK"
  return 0
}
trap cleanup EXIT

# run_launcher [VAR=value ...] -- args: the launcher in the project folder, with a private HOME and state dir.
run_launcher() {
  local envs=(); while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  (cd "$PROJ" && exec env HOME="$WORK/home" XDG_STATE_HOME="$WORK/state" COPILOT_POD_NO_UPDATE=1 \
     ${envs[@]+"${envs[@]}"} "$LAUNCHER" "$@")
}
# start_launcher [VAR=value ...] -- args: like run_launcher, in the background. LP is the launcher's own pid (the
# subshell execs it), so a signal sent to LP reaches the launcher and not a wrapper around it.
start_launcher() {
  local envs=(); while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  (cd "$PROJ" && exec env HOME="$WORK/home" XDG_STATE_HOME="$WORK/state" COPILOT_POD_NO_UPDATE=1 \
     ${envs[@]+"${envs[@]}"} "$LAUNCHER" "$@") &
  LP=$!; BG_PIDS+=("$LP")
}
# A pod is up once its container runs.
wait_for_pod() {
  local _; for _ in $(seq 1 240); do
    [ "$(docker ps -q --filter name=copilot-pod-run- | grep -c .)" -gt 0 ] && return 0; sleep 0.5; done; return 1
}

echo "host uid:gid $HOST_UID:$HOST_GID, docker $(docker version -f '{{.Server.Version}}' 2>/dev/null), inner images: ${INNER_IMAGES[*]}"

section "pod image: the tools the pod and its Docker CLI need"
for t in "copilot --version" "gh --version" "yq --version" "git --version" "docker --version" \
         "docker compose version" "docker buildx version"; do
  check "image has: $t" docker run --rm copilot-pod sh -c "$t"
done

section "pinned sidecar image: the contract the launcher relies on"
PIN="$(grep -o 'docker:[0-9a-z.-]*-dind-rootless@sha256:[0-9a-f]\{64\}' "$LAUNCHER" | head -n1)"
check "launcher pins a rootless dind image by digest" test -n "$PIN"
if [ -n "$PIN" ]; then
  check "pull $PIN" bash -c 'for i in 1 2 3; do docker pull -q "$0" && exit 0; sleep 5; done; exit 1' "$PIN"
  contract() { docker run --rm --entrypoint sh "$PIN" -c "$1"; }
  check "user rootless is 1000:1000 (the derived image renumbers exactly this)" contract "grep -q '^rootless:x:1000:1000:' /etc/passwd"
  check "group rootless is 1000" contract "grep -q '^rootless:x:1000:' /etc/group"
  check "subuid and subgid ranges are keyed by the user name" contract "grep -q '^rootless:[0-9]*:65536' /etc/subuid && grep -q '^rootless:[0-9]*:65536' /etc/subgid"
  check "newuidmap and the entrypoint exist" contract "command -v newuidmap && command -v dockerd-entrypoint.sh"
  check "data dir /home/rootless/.local/share/docker is owned by 1000" contract "[ \"\$(stat -c %u /home/rootless/.local/share/docker)\" = 1000 ]"
  check "docker CLI in the sidecar image (the launcher probes readiness with it)" contract "command -v docker"
fi

section "session: DOCKER=1 (rootless sidecar, mTLS, inner containers, project writes)"
# One session runs all steps and prints "STEP ok|FAIL <name>" lines, so there is one sidecar start for them all.
POD_SCRIPT='
step() { local n="$1" out rc; shift; out="$("$@" 2>&1)"; rc=$?
  if [ "$rc" = 0 ]; then echo "STEP ok $n"; else echo "STEP FAIL $n"; printf "%s\n" "$out" | tail -n 12 | sed "s/^/    | /"; fi; }
pick() { local r i; for r in "$@"; do for i in 1 2 3; do docker pull -q "$r" >/dev/null 2>&1 && { IMG="$r"; return 0; }; sleep 3; done; done; return 1; }
info() { docker info 2>&1 | grep -qi rootless && docker info 2>&1 | grep -q "Server Version"; }
tls_env() { [ "$DOCKER_TLS_VERIFY" = 1 ] && [ "$DOCKER_HOST" = tcp://dind:2376 ]; }
step docker-info-reports-rootless info
step tls-env-points-at-the-sidecar tls_env
pick "$@" && echo "STEP ok pull-inner-image" || { echo "STEP FAIL pull-inner-image"; exit 0; }
step inner-run docker run --rm "$IMG" echo inner-ok
inner_write() { docker run --rm -v "$PWD:$PWD" -w "$PWD" "$IMG" touch inner-root && [ "$(stat -c %u inner-root)" = "$(id -u)" ]; }
step inner-root-writes-the-project-as-the-host-user inner_write
inner_chown() { docker run --rm -v "$PWD:$PWD" -w "$PWD" "$IMG" sh -c "touch m && chown 5000:5000 m"; }
step inner-chown-to-another-uid inner_chown
inner_build() { printf "FROM %s\nRUN echo built > /built\n" "$IMG" > Dockerfile && docker build -q -t itest-build . >/dev/null && [ "$(docker run --rm itest-build cat /built)" = built ]; }
step inner-docker-build inner_build
compose_up() { printf "services:\n  s:\n    image: %s\n    command: [\"echo\", \"compose-ok\"]\n" "$IMG" > compose.yaml
  local out; out="$(docker compose up --abort-on-container-exit 2>&1)"; docker compose down >/dev/null 2>&1; grep -q compose-ok <<<"$out"; }
step inner-docker-compose compose_up
'
SESSION_OUT="$WORK/session.out"
run_launcher DOCKER=1 -- bash -c "$POD_SCRIPT" bash "${INNER_IMAGES[@]}" >"$SESSION_OUT" 2>&1; rc=$?
if [ "$rc" = 0 ]; then ok "session exits 0"; else fail "session exits 0 (got $rc)"; fi
session_failed=$([ "$rc" = 0 ] || echo 1)
while IFS= read -r line; do
  case "$line" in
    "STEP ok "*) ok "${line#STEP ok }" ;;
    "STEP FAIL "*) fail "${line#STEP FAIL }"; session_failed=1 ;;
  esac
done <"$SESSION_OUT"
[ "$(grep -c '^STEP ' "$SESSION_OUT")" -ge 8 ] || { fail "session ran all its steps"; session_failed=1; }
[ -z "$session_failed" ] || { echo "  session output:"; tail -n 60 "$SESSION_OUT" | indent; }

section "exit code of the pod is the exit code of the launcher"
run_launcher DOCKER=1 -- sh -c 'exit 7' >"$WORK/exit.out" 2>&1; rc=$?
if [ "$rc" = 7 ]; then ok "pod exit 7 -> launcher exit 7"; else fail "pod exit 7 -> launcher exit 7 (got $rc)"; tail -n 20 "$WORK/exit.out" | indent; fi

section "cache (DOCKER_CACHE=1)"
run_launcher DOCKER=1 DOCKER_CACHE=1 -- docker pull -q "${INNER_IMAGES[0]}" >"$WORK/cache1.out" 2>&1 \
  || run_launcher DOCKER=1 DOCKER_CACHE=1 -- docker pull -q "${INNER_IMAGES[1]:-${INNER_IMAGES[0]}}" >>"$WORK/cache1.out" 2>&1
check "first session creates the cache volume $CACHE_VOL" grep -q "created new $CACHE_VOL" "$WORK/cache1.out"
check "cache volume exists" docker volume inspect "$CACHE_VOL"
run_launcher DOCKER=1 DOCKER_CACHE=1 -- docker images >"$WORK/cache2.out" 2>&1
check "second session reuses the cache" grep -q "reusing $CACHE_VOL" "$WORK/cache2.out"
check "the pulled image is still there" grep -q alpine "$WORK/cache2.out"

section "a running cache session: exclusivity, TLS, SIGTERM"
start_launcher DOCKER=1 DOCKER_CACHE=1 -- sleep 300 >"$WORK/long.out" 2>&1
if wait_for_pod; then ok "cache session is up"; else fail "cache session is up"; tail -n 30 "$WORK/long.out" | indent; fi
run_launcher DOCKER=1 DOCKER_CACHE=1 -- true >"$WORK/conflict.out" 2>&1; rc=$?
if [ "$rc" != 0 ] && grep -q "docker rm -f copilot-pod-dind-cache-$CACHE_HASH" "$WORK/conflict.out"; then
  ok "a second session on the same cache is rejected with the leftover hint"
else fail "a second session on the same cache is rejected with the leftover hint (rc $rc)"; tail -n 10 "$WORK/conflict.out" | indent; fi
check "the first session is unaffected" test -n "$(docker ps -q --filter name=copilot-pod-run-)"

SIDECAR="$(docker ps -q --filter "name=copilot-pod-dind-cache-$CACHE_HASH" | head -n1)"
if [ -n "$SIDECAR" ]; then
  NET="$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' "$SIDECAR")"
  CERTS="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/certs"}}{{.Name}}{{end}}{{end}}' "$SIDECAR")"
  tls() { docker run --rm --network "$NET" -v "$CERTS:/certs:ro" --entrypoint sh copilot-pod -c "$1"; }
  tls_out="$(tls 'curl -s -m 5 http://dind:2376/_ping' 2>&1)"
  check "plain HTTP on 2376 is refused (HTTPS server)" grep -q 'HTTP request to an HTTPS server' <<<"$tls_out"
  if tls 'curl -s -m 5 http://dind:2375/_ping' >/dev/null 2>&1; then fail "port 2375 is closed"; else ok "port 2375 is closed"; fi
  if tls 'curl -s -m 5 --cacert /certs/client/ca.pem https://dind:2376/_ping' >/dev/null 2>&1; then fail "TLS without a client certificate is refused"; else ok "TLS without a client certificate is refused"; fi
  if tls 'cd /tmp && openssl req -x509 -newkey rsa:2048 -nodes -keyout k.pem -out c.pem -subj /CN=other -days 1 2>/dev/null && curl -s -m 5 --cacert /certs/client/ca.pem --cert c.pem --key k.pem https://dind:2376/_ping' >/dev/null 2>&1
  then fail "a client certificate from another CA is refused"; else ok "a client certificate from another CA is refused"; fi
  ping_out="$(tls 'curl -s -m 5 --cacert /certs/client/ca.pem --cert /certs/client/cert.pem --key /certs/client/key.pem https://dind:2376/_ping' 2>&1)"
  check "the pod's own credentials are accepted" test "$ping_out" = OK
else
  fail "found the cache session's sidecar for the TLS checks"
fi
kill -TERM "$LP" 2>/dev/null; wait "$LP" 2>/dev/null; rc=$?
if [ "$rc" = 143 ]; then ok "SIGTERM to the launcher -> exit 143"; else fail "SIGTERM to the launcher -> exit 143 (got $rc)"; tail -n 20 "$WORK/long.out" | indent; fi

section "cache pruning (DOCKER_CACHE_MAX_AGE_DAYS)"
docker volume create "$PRUNE_VOL" >/dev/null 2>&1
mkdir -p "$WORK/state/copilot-pod/caches"; touch -d '3 days ago' "$WORK/state/copilot-pod/caches/$PRUNE_VOL" 2>/dev/null \
  || touch -t "$(date -d '3 days ago' +%Y%m%d%H%M 2>/dev/null || date -v-3d +%Y%m%d%H%M)" "$WORK/state/copilot-pod/caches/$PRUNE_VOL"
run_launcher DOCKER=1 DOCKER_CACHE=1 DOCKER_CACHE_MAX_AGE_DAYS=1 -- true >"$WORK/prune.out" 2>&1
check "a cache unused for longer than the limit is removed" bash -c '! docker volume inspect "$0"' "$PRUNE_VOL"
check "the current project's cache is kept" docker volume inspect "$CACHE_VOL"

section "nothing left behind"
for _ in $(seq 1 30); do
  [ "$(count ps -aq --filter label=copilot-pod.run)" = "$PRE_CONTAINERS" ] && break; sleep 1
done
check "no sidecar containers left" test "$(count ps -aq --filter label=copilot-pod.run)" = "$PRE_CONTAINERS"
check "no networks left" test "$(count network ls -q --filter name=copilot-pod-net-)" = "$PRE_NETWORKS"
check "no certificate volumes left" test "$(count volume ls -q --filter name=copilot-pod-certs-)" = "$PRE_CERTS"

echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
