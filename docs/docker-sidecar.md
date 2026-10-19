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
   the pod does not exist yet).
6. The pod gets `--init` (only with `DOCKER=1`): with a bare shell or node as PID 1 the stop signal is
   ignored and the pod dies only after the 10s grace period (exit 137).
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

A launcher backgrounded by a non-interactive shell (script, CI) inherits SIGINT as ignored and Bash cannot
override that; such launches must be cancelled with SIGTERM (documented in the README).

## Host requirement on Ubuntu 24.04+

Rootless dockerd needs unprivileged user namespaces. With `kernel.apparmor_restrict_unprivileged_userns=1`
(the default there) the sidecar dies with `rootlesskit ... fork/exec /proc/self/exe: operation not
permitted`. The launcher detects the exited sidecar immediately, prints its logs and points to the README
section "Requirements for DOCKER=1" (sysctl.d setting and how to undo it). For tests:
`sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0`, and set it back to `1` afterwards.

## Testing

There is no automated test suite. Two layers have been used:

**Stubbed `docker`** (no daemon needed). Put a fake `docker` script first on `PATH` that logs every call
and is steered by environment variables (pod exit code, long-running pod, slow sidecar start, name
conflict, dead sidecar, `volume rm` results, failing `volume ls`). Override `HOME` and `XDG_STATE_HOME`
and set `COPILOT_POD_NO_UPDATE=1`. Make each test discriminating: copy the launcher without the fix
(`sed '/line/d'`) and check that the test fails there. Covered this way: command sequence, exit-code
propagation, cache create/reuse/prune (old, young, in-use, missing stamps, paths with spaces),
exclusivity conflict, startup and double signals, early sidecar exit.

**Real Docker checklist** (run from a project folder; replace the alias with the full path to
`copilot-pod` inside `bash -c`):

```sh
DOCKER=1 copilot-pod docker info                                   # sidecar + mTLS work
DOCKER=1 copilot-pod docker run --rm hello-world                   # inner containers work
DOCKER=1 DOCKER_CACHE=1 copilot-pod docker pull hello-world        # then:
DOCKER=1 DOCKER_CACHE=1 copilot-pod docker images                  # "reusing ... (1 images ...)"
DOCKER=1 DOCKER_CACHE=1 copilot-pod sleep 60                       # 2nd terminal, same folder:
DOCKER=1 DOCKER_CACHE=1 copilot-pod true                           # must be rejected
DOCKER=1 copilot-pod sleep 60 </dev/null & p=$!; sleep 30; kill -INT $p; wait $p   # 143 after ~2s
bash -c 'DOCKER=1 /path/to/copilot-pod sleep 60 </dev/null & p=$!; sleep 30; kill -TERM $p; wait $p'
docker ps -a --filter name=copilot-pod; docker network ls --filter name=copilot-pod; \
  docker volume ls --filter name=copilot-pod                       # only the cache volume may remain
```

Verified so far on native Linux (Ubuntu, kernel 7.0, uid 1000): everything above. Not yet verified: macOS,
Windows/WSL2, a host uid other than 1000 (the client certificates are `0644` in directories `1777`, so it
should work), the double-Ctrl-C-during-startup cleanup and the 90-day prune on a real daemon.
Current status and open items are tracked in the pull request description.
