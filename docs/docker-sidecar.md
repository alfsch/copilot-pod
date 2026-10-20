# Docker sidecar (`DOCKER=1`): maintainer notes

User-facing documentation is in the README ("Using Docker inside the pod"). This file is for people who
change the feature: how it is built, why, and how to test it.

## What it does

`DOCKER=1 copilot-pod` gives the pod its own throwaway Docker daemon without weakening the pod:

```
host Docker  ──runs──▶  pod (copilot-pod image)         cap-drop=ALL, no-new-privileges, seccomp, --init
             └─runs──▶  sidecar (docker:28-dind-rootless, --privileged)
                         ▲  private per-run network, mTLS on 2376 (port never published)
                         └─ certs in a per-run volume, mounted read-only into the pod
```

- Only the sidecar is privileged; its dockerd runs as uid 1000 in a user namespace. The host Docker
  socket is never mounted. The pod only has the `docker` CLI (plus Compose and Buildx) with `DOCKER_HOST`
  pointing at the sidecar.
- `DOCKER_CACHE=1` additionally keeps the sidecar's data directory in a per-project named volume.
- Everything is in the `copilot-pod` launcher script; `install.sh`, `uninstall.sh`, `Dockerfile` and
  `renovate.json` have small supporting changes (CLI in the image, volume cleanup on uninstall, digest
  pins kept current by Renovate).

## Lifecycle invariants (keep these when changing the launcher)

1. Every per-run resource name contains a unique `RUN_ID` (PID + time + random). Cleanup can therefore
   only ever touch resources of its own run.
2. The sidecar is found by the label `copilot-pod.run=$RUN_ID`, never by name. A signal can land right
   after `docker run -d` created it but before the launcher noted it, and with a cache a fixed name may
   belong to another session.
3. The sidecar is started without `--rm` so its logs survive a startup failure; `cleanup_dind` stops it
   (10s grace) and removes it with `-v`.
4. `cleanup_dind` is the `EXIT` trap and ignores INT/TERM/HUP, so a second Ctrl-C cannot leave the
   sidecar, network or certificate volume behind.
5. The pod runs in the background and the launcher polls `kill -0` before a single `wait`, so the
   pod's exit status is never confused with a signal-interrupted `wait` (128+N). Startup traps are
   `exit 143/130/129`; once the pod runs, the trap is `stop_pod` (`docker stop`, or kill the client if
   the pod does not exist yet). A stop request is remembered in `STOP_REQUESTED` and the poll loop
   repeats `docker stop` until the pod is gone. Two windows need that: before `POD_PID` is known, and
   between Docker creating the pod container and starting it, where `docker stop` succeeds without
   effect (measured: rc 0, state stays `created`, the waiting `docker run` then starts it anyway; 15/15
   stops lost without the retry, 0/15 with it).
6. The pod gets `--init` (only with `DOCKER=1`): with a bare shell or node as PID 1 the stop signal is
   ignored and the pod dies only after the 10s grace period (exit 137). `--init` is not enough for the
   default command: interactive Bash (TTY) ignores SIGTERM even as a child of tini (measured with
   `docker stop -t 10`: SIGTERM takes 10s and ends in 137, SIGHUP takes under 1s and ends in 129). So when
   no command is given, or it is a plain `bash`, the pod also gets `--stop-signal=SIGHUP` and reports 129;
   other commands (including `bash -c ...`, which is not interactive) keep SIGTERM and report 143. Not in the Dockerfile (`STOPSIGNAL`) on purpose: that would change the signal
   for `copilot` and every other command too.
   The sidecar gets `--init` too, for the same reason at another time: its image entrypoint is a shell that
   runs as PID 1 and generates the TLS certificates before it execs dockerd, and a PID 1 without a handler
   ignores SIGTERM, so a signal during startup cost the whole 10s stop timeout (exit 137). Measured with
   `docker stop -t 10` 0.5s after start: 10.3s without `--init`, 0.2s with; a stop of a ready sidecar is
   1.3s either way (graceful, exit 0). Launcher abort during startup: ~11s before, 1-2s now.
7. Without `DOCKER=1` the launcher still `exec`s docker, exactly as before.

## Cache design

- Volume `copilot-pod-docker-<first 16 hex chars of sha256(pwd -P)>`, one per physical project path.
- **Exclusivity:** a cache session's sidecar has the fixed name `copilot-pod-dind-cache-<hash>`. Docker
  rejects a second container with that name atomically, so two sessions can never run dockerd on the same
  data directory. A leftover after `kill -9` is removed with `docker rm -f <name>` (the error message
  says so).
- **Auto-prune:** Docker does not record volume last-use. Each cache has an empty stamp file in
  `~/.local/state/copilot-pod/caches/` (mtime = last use), touched at session start and end. Every start
  removes volumes whose stamp is older than `DOCKER_CACHE_MAX_AGE_DAYS` (default 90, 0 disables). A
  volume in use cannot be removed; a volume already gone only loses its stamp. The stamps live outside
  `~/.copilot-pod`, which is mounted into the pod, so a session cannot edit them.
- Accepted race: a start touching a cache just as another start deletes it can only cost a cache that
  has been idle for months. That is why no locking exists.

## Decisions and rejected alternatives

The first version had lock files, a guard around the locks and a shared usage file. Each automated review
round found a new race in that machinery, and each fix added a layer. It was replaced by the stamp files and
the sidecar-name reservation above (about 120 fewer lines). **Do not reintroduce locks or a shared state
file**; weigh new review findings against KISS before implementing them.

Deliberately not done:

- Polling replaced by plain `wait` (exit-code ambiguity, see invariant 5).
- Support for a remote `DOCKER_HOST` (the base launcher mounts `$PWD` and cannot work there either).
- Paths containing `:` (the base launcher's `-v "$PWD:$PWD"` already breaks on them).
- A warning when removing the sidecar fails (optional; the "cache in use" message already names the
  leftover).
- Dropping `--privileged` for a minimal capability set (could not be tested).
- Mapping the sidecar user to the host uid (see "Known limitation: host uid other than 1000").

A launcher backgrounded by a non-interactive shell (script, CI) inherits SIGINT as ignored and Bash cannot
override that; such launches must be cancelled with SIGTERM (documented in the README).

## Known limitation: host uid other than 1000

The sidecar's dockerd runs as uid 1000 (the image's `rootless` user) and the project folder is bind-mounted
into it. An inner container's root maps to that uid, and `--user N` maps to a subordinate uid, so on a host
where the project folder belongs to another uid neither can write to it. Measured on a real daemon with
host uid 1001 and a folder owned by 1001 (mode 775):

- the pod itself (`--user 1001:1001`) can write; the file is owned by 1001;
- `docker run -v "$PWD:$PWD" alpine touch f` inside the pod: `Permission denied`, as root and with
  `--user 1001:1001`;
- with the folder mode 777 the root case works, and the file is then owned by uid 1000 on the host.

Workarounds for users: `chmod o+w` the folder, or chown the files created by inner containers afterwards (that needs `sudo` on the host).
A real fix (mapping the sidecar user to the host uid) is a design change and is not part of this feature. To
check it on a host: run the three commands above from a project folder that is not under `/tmp`: a daemon that
runs in a VM or another mount namespace may not see that path, and then even the pod gets `Permission denied`
on an empty root-owned directory, which looks the same but is a test setup problem.

## Host requirement on Ubuntu 24.04+

Rootless dockerd needs unprivileged user namespaces. With `kernel.apparmor_restrict_unprivileged_userns=1`
(the default there) the sidecar dies with `rootlesskit ... fork/exec /proc/self/exe: operation not
permitted`. The launcher detects the exited sidecar immediately, prints its logs and points to the README
section "Requirements for DOCKER=1" (sysctl.d setting and how to undo it). For tests:
`sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0`, and set it back to `1` afterwards.

## Testing

There is no CI. Two layers have been used:

**Stubbed `docker`** (no daemon needed): `tests/stubbed-docker.sh` runs the cases below and then a set of
mutants (the launcher with one fix removed) that each must make a test fail. Run it after every launcher
change; `tests/stubbed-docker.sh test_prune` runs a single test. Its description of the approach: Put a fake `docker` script first on `PATH` that logs every call
and is steered by environment variables (pod exit code, long-running pod, slow sidecar start, name
conflict, dead sidecar, `volume rm` results, failing `volume ls`). Override `HOME` and `XDG_STATE_HOME`
and set `COPILOT_POD_NO_UPDATE=1`. Make each test discriminating: copy the launcher without the fix
(`sed '/line/d'`) and check that the test fails there. Covered this way: command sequence, exit-code
propagation, cache create/reuse/prune (old, young, in-use, missing stamps, paths with spaces),
exclusivity conflict, TERM/INT/HUP during startup and while the pod runs, a second signal during
cleanup, a stop during pod creation, early sidecar exit. The INT tests start the launcher with `set -m`:
a background job of a non-interactive shell otherwise has SIGINT ignored.

**Real Docker checklist** (run from a project folder; replace the alias with the full path to
`copilot-pod` inside `bash -c`):

```sh
DOCKER=1 copilot-pod docker info                                   # sidecar + mTLS work
DOCKER=1 copilot-pod docker run --rm hello-world                   # inner containers work
DOCKER=1 DOCKER_CACHE=1 copilot-pod docker pull hello-world        # then:
DOCKER=1 DOCKER_CACHE=1 copilot-pod docker images                  # "reusing ... (1 images ...)"
DOCKER=1 DOCKER_CACHE=1 copilot-pod sleep 60                       # 2nd terminal, same folder:
DOCKER=1 DOCKER_CACHE=1 copilot-pod true                           # must be rejected
# Signals. Startup (sidecar + pod) takes several seconds, so the signal must land once the pod runs: wait
# for that (sleep 30 is a generous guess), then time `wait`. Expect 143, 2-3s after the signal (pod stop
# 0.4s, sidecar stop 1.3s, the rest are docker calls). A signal DURING startup is a different path: exit
# 130 (INT), 129 (HUP) or 143 (TERM) and 1-2s (the sidecar runs under --init, see invariant 6).
DOCKER=1 copilot-pod sleep 60 </dev/null & p=$!; sleep 30; s=$SECONDS; kill -INT $p; wait $p; echo "exit=$? $((SECONDS-s))s"
bash -c 'DOCKER=1 /path/to/copilot-pod sleep 60 </dev/null & p=$!; sleep 30; kill -TERM $p; wait $p'
docker ps -a --filter name=copilot-pod; docker network ls --filter name=copilot-pod; \
  docker volume ls --filter name=copilot-pod                       # only the cache volume may remain
# TLS must refuse everything without the pod's credentials. While a session runs, from a second container on
# its network (copilot-pod-net-<id>, certs in copilot-pod-certs-<id>), each of these must fail: plain TCP to
# 2376 ("HTTP request to an HTTPS server"), TLS without a client cert, TLS with a client cert from another CA
# ("certificate required"), plain TCP to 2375. With --tlscacert/--tlscert/--tlskey from the certs volume it works.
```

Which of these checks have been run, where, and what is still open is tracked in the pull request description,
not here, so it cannot go stale.
