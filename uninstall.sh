#!/usr/bin/env bash
set -euo pipefail

# ANSI color codes; auto-disabled when stdout isn't a TTY (e.g. piped to a logfile, run in CI).
BOLD=$'\e[1m'; BLUE=$'\e[34m'; GREEN=$'\e[32m'; RED=$'\e[31m'; DIM=$'\e[2m'; RESET=$'\e[0m'
[[ -t 1 ]] || { BOLD=; BLUE=; GREEN=; RED=; DIM=; RESET=; }
info() { printf '%s●%s %s%s%s\n' "$BLUE" "$RESET" "$BOLD" "$*" "$RESET"; }
ok()   { printf '%s✓%s %s\n'       "$GREEN" "$RESET" "$*"; }
err()  { printf '%s✗%s %s\n'       "$RED"   "$RESET" "$*" >&2; }
# `trap - ERR` disarms the ERR trap below so the explicit `exit 1` doesn't double-report.
die()  { err "$*"; trap - ERR; exit 1; }
trap 'err "uninstall.sh failed at line $LINENO"' ERR

STATE_DIR="$HOME/.copilot-pod"
IMAGE="copilot-pod"

info "Will remove"
printf '  %simage:%s %s\n' "$DIM" "$RESET" "$IMAGE"
printf '  %sdir:  %s %s %s(auth + session history)%s\n' "$DIM" "$RESET" "$STATE_DIR" "$DIM" "$RESET"
printf '  %svolumes:%s copilot-pod-docker-* %s(DOCKER_CACHE image caches, if any)%s\n' "$DIM" "$RESET" "$DIM" "$RESET"
echo

info "Will NOT remove"
printf '  %snode:24-slim base image (docker rmi node:24-slim to clear)%s\n' "$DIM" "$RESET"
printf '  %sDocker build cache (docker builder prune to clear)%s\n' "$DIM" "$RESET"
printf '  %sthis repo folder (delete it yourself)%s\n' "$DIM" "$RESET"
echo

# `|| reply=""` so that EOF / non-interactive stdin (where read returns non-zero) is treated as
# a declined prompt under `set -e`, rather than tripping the ERR trap with a confusing line error.
read -r -p "Proceed? [y/N] " reply || reply=""
[[ "$reply" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
echo

info "Removing image '$IMAGE'"
# Probe with `image ls -q`, not `image inspect`: some Docker Desktop builds have a broken
# `image inspect <name>` that false-negatives on a present image, which would make us wrongly
# report "not present" and leave the image behind. `ls -q` resolves the name like `rmi` does.
if [ -n "$(docker image ls -q "$IMAGE" 2>/dev/null)" ]; then
  # Dim + indent the rmi output the same way install.sh dims `docker build` output.
  docker rmi -f "$IMAGE" 2>&1 \
    | sed $'s/\e\\[[0-9;]*m//g' \
    | while IFS= read -r line; do printf '%s  %s%s\n' "$DIM" "$line" "$RESET"; done
  ok "Image '$IMAGE' removed"
else
  ok "Image '$IMAGE' was not present"
fi
echo

info "Removing Docker cache volumes"
# --filter name= matches substrings, so keep only the names the launcher generates.
# A failed listing must not look like "no caches", or the stamps would be deleted below.
_all="$(docker volume ls -q --filter name=copilot-pod-docker- 2>/dev/null)" \
  || die "Could not list Docker volumes (is the Docker daemon running?). The host directory was not removed."
# --filter name= matches substrings, so keep only the names the launcher generates.
_vols="$(grep -E '^copilot-pod-docker-[0-9a-f]{16}$' <<<"$_all" || true)"
if [ -n "$_vols" ]; then
  # shellcheck disable=SC2086
  docker volume rm -f $_vols >/dev/null 2>&1 || die "Some cache volumes are in use; close running sessions and retry. The host directory was not removed."
  ok "Removed Docker cache volumes"
else
  ok "No Docker cache volumes present"
fi
# The last-use stamps go regardless of volumes: they can outlive volumes that were deleted by hand.
rm -rf "${XDG_STATE_HOME:-$HOME/.local/state}/copilot-pod"
echo

info "Removing host directory"
if [ -d "$STATE_DIR" ]; then
  rm -rf "$STATE_DIR"
  ok "Removed $STATE_DIR"
else
  ok "$STATE_DIR was not present"
fi
echo

ok "Done"
