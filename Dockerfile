# If you bump this tag, also update the literal in uninstall.sh.
FROM node:24-slim

# git/curl/less are baseline dev tools; jq and gh are reached for by Copilot's built-in workflows
# (JSON pipelines and the GitHub CLI for PRs/issues/releases). ca-certificates is needed for HTTPS.
# python3, pip and venv are for scripting; poppler-utils provides pdftotext, qpdf handles PDF
# manipulation, and tesseract-ocr does OCR (English and German language data).
RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates curl less jq gh \
      python3 python3-pip python3-venv poppler-utils qpdf tesseract-ocr tesseract-ocr-eng tesseract-ocr-deu \
 && rm -rf /var/lib/apt/lists/*

# yq (mikefarah's Go implementation, not Debian's Python wrapper of the same name) isn't in apt, so
# copy the static binary out of the official multi-arch image; Docker picks the right architecture.
# The tag@digest pair is kept current by Renovate (see renovate.json), and the digest pins the exact
# image contents.
COPY --from=mikefarah/yq:4.54.1@sha256:4b3d9475d65571d28cbb19544d3820ec2945e4c8b2f18279394282b8dc3a592e /usr/bin/yq /usr/local/bin/yq

# Docker CLI (with the compose and buildx plugins) only, no daemon. Pinned by digest, kept current by Renovate. It is inert unless the launcher is run with
# DOCKER=1, which points it at a rootless Docker-in-Docker sidecar via DOCKER_HOST.
COPY --from=docker:28-cli@sha256:625d9431a9f54c5a2bc90f24f0e1c3d55b1349fd857dd85035f98c2c9acbdd4d /usr/local/bin/docker /usr/local/bin/docker
COPY --from=docker:28-cli@sha256:625d9431a9f54c5a2bc90f24f0e1c3d55b1349fd857dd85035f98c2c9acbdd4d /usr/local/libexec/docker/cli-plugins/docker-compose /usr/local/libexec/docker/cli-plugins/docker-compose
COPY --from=docker:28-cli@sha256:625d9431a9f54c5a2bc90f24f0e1c3d55b1349fd857dd85035f98c2c9acbdd4d /usr/local/libexec/docker/cli-plugins/docker-buildx /usr/local/libexec/docker/cli-plugins/docker-buildx

# Override at build time with --build-arg COPILOT_CLI_VERSION=2.x.y to pin a specific
# version. Default "latest" is the npm dist-tag for the official release (@github/copilot has no
# "stable" tag).
ARG COPILOT_CLI_VERSION=latest

# install.sh resolves "latest" to a concrete version, so the version literal itself is the cache
# key and this layer caches normally. If resolution fails, install.sh passes CACHEBUST=$(date +%s)
# to force a fresh refetch.
ARG CACHEBUST=1
RUN npm install -g @github/copilot@${COPILOT_CLI_VERSION}

# Recorded for the copilot-pod launcher: it only auto-updates images built from the "latest" channel
# (COPILOT_CLI_CHANNEL, what the user asked for) and compares the installed version label against
# npm's current latest. Declared after the install so changing them doesn't invalidate that layer.
ARG COPILOT_CLI_CHANNEL=${COPILOT_CLI_VERSION}
LABEL copilot-pod.channel=${COPILOT_CLI_CHANNEL} \
      copilot-pod.version=${COPILOT_CLI_VERSION}

# We DO NOT use `USER node` here. Instead, we pass `--user "$(id -u):$(id -g)"` dynamically
# at runtime in the `copilot-pod` script. This ensures perfect file permission alignment
# between the host and the container, especially on Linux environments.
# Create a dedicated, globally writable home directory for our dynamic runtime user.
RUN mkdir -p /home/copilot-pod && chmod 777 /home/copilot-pod

# Interactive-shell setup, appended to /etc/bash.bashrc. Only interactive bash sources this file, so
# none of it touches the non-interactive `copilot-pod copilot ...` path. The dynamic, /etc/passwd-less
# user has no $HOME/.bashrc of its own, so these baseline conveniences have to live in the system-wide
# rc. Heredoc keeps the escapes readable (BuildKit, which install.sh already requires via
# --progress=plain, supports it).
RUN cat >> /etc/bash.bashrc <<'EOF'

# Colored prompt: green label, blue path — the conventional Debian default look. \[...\] wraps the
# non-printing escapes so bash measures the prompt width correctly. The "copilot-pod" label also
# hides the "I have no name!" warning a dynamic, passwd-less user would otherwise show.
PS1='\[\e[1;32m\]copilot-pod\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ '

# Basic, conventional coloring for the most-used commands. dircolors supplies the standard LS_COLORS
# palette; the aliases enable color only when output is a terminal (so piped output stays clean).
if command -v dircolors >/dev/null 2>&1; then eval "$(dircolors -b)"; fi
alias ls='ls --color=auto'
alias grep='grep --color=auto'
EOF

CMD ["bash"]
