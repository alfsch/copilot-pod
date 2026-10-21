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
  signals) is covered by `tests/integration.sh` (run by `.github/workflows/integration-tests.yaml`) and, for
  what that does not check, by the checklist in `docs/docker-sidecar.md`, on a host with Docker.
- Renovate merges updates of GitHub Actions and of the tooling images (docker CLI, DIND sidecar, node base image,
  yq), majors included, as soon as the required checks pass (`renovate.json`), so those checks are the only
  review such an update gets. If a merged update breaks something the tests did not notice, the fix includes a
  new test for it. A test must not name a version Renovate bumps (a stub test once expected `docker:28-...`).
- The stub tests also run on macOS (system Bash 3.2, BSD tools): keep them portable, with no `mapfile` and no
  GNU-only flags (see the helpers in `tests/stubbed-docker.sh`).
- Rootless DinD needs unprivileged user namespaces; on Ubuntu 24.04+ that means
  `kernel.apparmor_restrict_unprivileged_userns=0` for the test (set it back to `1` afterwards).
- After every edit run `for f in copilot-pod install.sh uninstall.sh tests/stubbed-docker.sh; do bash -n "$f"; done`
  (`bash -n a b c` parses only `a`); CI does that and also runs ShellCheck (`-S warning`).

## Status

Current status and open items of work in progress are in the description of the open pull request, not in
this file, so they cannot go stale here.
