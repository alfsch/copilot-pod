# copilot-pod

Runs the GitHub Copilot CLI in a hardened Docker container scoped to the current folder. The launcher is the
`copilot-pod` bash script; `install.sh` builds the image, `uninstall.sh` removes everything. User docs are in
`README.md`.

## Before changing the Docker sidecar (`DOCKER=1` / `DOCKER_CACHE=1`)

- Read [docs/docker-sidecar.md](docs/docker-sidecar.md) first: architecture, the lifecycle invariants the
  launcher must keep, the cache design and the testing approach.
- Keep it simple. Cache exclusivity is the fixed sidecar name and cache pruning uses one stamp file per
  cache; an earlier version with lock files and a shared state file produced a new race with every fix.
  Do not reintroduce locks or a shared usage file, and weigh each automated review finding against that
  before implementing it.
- Without `DOCKER=1` the launcher must keep `exec`ing docker unchanged.

## Testing

- The stub tests (`tests/stubbed-docker.sh`, run by `.github/workflows/stub-tests.yaml` on pull requests) need
  no Docker daemon, which the Claude sandbox usually lacks. Test launcher changes with them, and make each test
  fail without the fix (see the docs). Anything that needs a real daemon (rootless sidecar, TLS, cache volumes,
  signals) has to be run on a host with Docker; the checklist is in `docs/docker-sidecar.md`.
- Rootless DinD needs unprivileged user namespaces; on Ubuntu 24.04+ that means
  `kernel.apparmor_restrict_unprivileged_userns=0` for the test (set it back to `1` afterwards).
- Run `bash -n copilot-pod uninstall.sh install.sh tests/stubbed-docker.sh` after every edit; CI also runs
  ShellCheck (`-S warning`) on them.

## Status

Current status and open items of work in progress are in the description of the open pull request, not in
this file, so they cannot go stale here.
