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
trap 'err "install.sh failed at line $LINENO"' ERR

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="copilot-pod"
# Default to npm's "latest" dist-tag (the official release; @github/copilot has no "stable" tag).
# Set COPILOT_CLI_VERSION=x.y.z to pin a version.
COPILOT_CLI_VERSION="${COPILOT_CLI_VERSION:-latest}"

command -v docker >/dev/null || die "Docker is required but not on PATH."
docker info >/dev/null 2>&1 || die "Docker daemon is not running."

# What the user asked for ("latest" or a number); stored as an image label so the
# copilot-pod launcher knows whether it may auto-update this image.
CHANNEL="$COPILOT_CLI_VERSION"

# Resolve "latest" to a concrete version from the npm registry, so the version number becomes the
# cache key: the npm layer is reused while latest is unchanged and rebuilt when it moves. If the
# lookup fails, the tag stays as is and gets the CACHEBUST fallback below.
if [ "$COPILOT_CLI_VERSION" = "latest" ]; then
  RESOLVED_LATEST="$(curl -fsSL --max-time 10 https://registry.npmjs.org/-/package/@github/copilot/dist-tags 2>/dev/null \
    | sed -n 's/.*"latest"[[:space:]]*:[[:space:]]*"\([0-9][^"]*\)".*/\1/p' || true)"
  if [ -n "$RESOLVED_LATEST" ]; then
    COPILOT_CLI_VERSION="$RESOLVED_LATEST"
  else
    printf '%s  Could not resolve "latest" from npm; building without cache for this step.%s\n' "$DIM" "$RESET"
  fi
fi

# For pinned versions, the version literal in the Dockerfile RUN line is itself the cache key,
# so the layer rebuilds whenever the pin changes — no extra invalidator needed.
# For an unresolved "latest" dist-tag, the literal never changes while the version
# it points to does, so we pass CACHEBUST=$(date +%s) to force a refetch.
BUILD_ARGS=("--build-arg" "COPILOT_CLI_VERSION=$COPILOT_CLI_VERSION" "--build-arg" "COPILOT_CLI_CHANNEL=$CHANNEL")
if [[ ! "$COPILOT_CLI_VERSION" =~ ^[0-9] ]]; then
  BUILD_ARGS+=("--build-arg" "CACHEBUST=$(date +%s)")
fi

info "Preflight"
printf '  %sdocker:        %s %s\n' "$DIM" "$RESET" "$(docker --version)"
printf '  %srepo:          %s %s\n' "$DIM" "$RESET" "$REPO_DIR"
printf '  %simage:         %s %s\n' "$DIM" "$RESET" "$IMAGE"
printf '  %scopilot-cli:   %s %s\n' "$DIM" "$RESET" "$COPILOT_CLI_VERSION"
echo

# Build under a temporary tag and only move the real tag after the new image proves it works, so a
# failed build or a broken `copilot` binary never replaces a working image (this matters because
# copilot-pod auto-updates on start). The tag is unique per invocation ($$ = PID) so concurrent
# installers can never verify one image and promote another; the EXIT trap removes it on any exit
# (failed build, failed verification, success), leaving only the promoted copilot-pod tag.
TMP_IMAGE="$IMAGE:new-$$"
trap 'docker rmi "$TMP_IMAGE" >/dev/null 2>&1 || true' EXIT

info "Building image '$IMAGE'"
# Stream the build output dimmed and indented. `--progress=plain` disables BuildKit's animated
# TUI (which can't be re-styled externally); the sed strips Docker's own ANSI codes so they don't
# cancel our dim formatting; the while-read prefixes each line with dim + 2-space indent.
docker build \
  --progress=plain \
  "${BUILD_ARGS[@]}" \
  -t "$TMP_IMAGE" "$REPO_DIR" 2>&1 \
  | sed $'s/\e\\[[0-9;]*m//g' \
  | while IFS= read -r line; do printf '%s  %s%s\n' "$DIM" "$line" "$RESET"; done
ok "Image built"
echo

info "Verifying"
# `copilot --version` prints the resolved npm version. Wrapped in if/else so a failure is reported
# with a clear message instead of tripping the ERR trap; the previous image stays untouched.
if RESOLVED_VERSION="$(docker run --rm "$TMP_IMAGE" copilot --version 2>&1)"; then
  printf '  %scopilot-cli:   %s %s\n' "$DIM" "$RESET" "$RESOLVED_VERSION"
else
  die "New image failed 'copilot --version' ($RESOLVED_VERSION); keeping the previous '$IMAGE' image."
fi
docker tag "$TMP_IMAGE" "$IMAGE:latest"
ok "Image '$IMAGE' installed"
echo

info "Next steps"
printf '  cd into your work-in-progress project folder first, then:\n'
printf '    Open shell in pod:          %s%s/copilot-pod%s\n' "$BOLD" "$REPO_DIR" "$RESET"
printf '    Or run Copilot directly:    %s%s/copilot-pod copilot --yolo%s\n' "$BOLD" "$REPO_DIR" "$RESET"
printf '    Shell with Docker:          %sDOCKER=1 %s/copilot-pod%s\n' "$BOLD" "$REPO_DIR" "$RESET"
printf '    Copilot with Docker:        %sDOCKER=1 %s/copilot-pod copilot --yolo%s\n' "$BOLD" "$REPO_DIR" "$RESET"
printf '    Docker + image cache:       %sDOCKER=1 DOCKER_CACHE=1 %s/copilot-pod%s\n' "$BOLD" "$REPO_DIR" "$RESET"
printf '    Optional shell alias:       %salias copilot-pod=%s/copilot-pod%s\n' "$BOLD" "$REPO_DIR" "$RESET"
