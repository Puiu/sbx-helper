FROM docker/sandbox-templates:opencode-docker
USER root
RUN apt-get update && apt-get install -y jq libicu-dev ca-certificates \
    binutils clang curl git gnupg2 libc6 libcurl4-openssl-dev libedit2 \
    libgcc-13-dev libpython3-dev libsqlite3-0 libstdc++-13-dev libxml2-dev \
    libz3-dev pkg-config tzdata uuid-dev zlib1g-dev unzip

# Noble compat libs: the ubuntu24.04 Swift toolchain links libxml2.so.2
# (resolute only ships libxml2.so.16) and lldb links libpython3.12
# (resolute only ships 3.14). Noble's libxml2/libicu74/libpython3.12 install
# alongside with no conflicts — those package names don't exist on resolute,
# and every shared dep resolves to the newer resolute version. The noble
# source is removed afterwards, leaving clean resolute-only apt sources.
RUN ARCH=$(dpkg --print-architecture) \
    && if [ "$ARCH" = arm64 ]; then MIRROR=http://ports.ubuntu.com/ubuntu-ports; else MIRROR=http://archive.ubuntu.com/ubuntu; fi \
    && echo "deb $MIRROR noble main universe" > /etc/apt/sources.list.d/noble-compat.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends libxml2 libicu74 libpython3.12 \
    && rm /etc/apt/sources.list.d/noble-compat.list \
    && apt-get update

# Managed OpenCode config. sbx does not carry host user-level config
# (~/.config/opencode/opencode.json, auth.json) into the sandbox, so defaults
# that must survive (re)creates belong here: /etc/opencode is untouched by sbx
# and loads at the highest-precedence (managed) tier on Linux.
# The Zen API key is NOT baked in — it is referenced via {env:...} substitution
# and injected at sandbox runtime via `sbx secret set-custom` (see README.md).
# The superpowers + context7 plugins ARE baked in: declared below (managed tier
# survives sbx recreates even if user-level config is rewritten) and pre-warmed
# into the image cache further down, so no manual install is needed in new sandboxes.
# statusLine wiring is EXPERIMENTAL: it mirrors the claude template, but
# OpenCode's statusline JSON schema differs from Claude Code's, so the shared
# statusline-command.sh may render empty fields until it is adapted.
RUN mkdir -p /etc/opencode \
    && printf '%s\n' \
        '{' \
        '  "$schema": "https://opencode.ai/config.json",' \
        '  "plugin": [' \
        '    "superpowers@git+https://github.com/obra/superpowers.git",' \
        '    "@upstash/context7-opencode"' \
        '  ],' \
        '  "provider": {' \
        '    "opencode": {' \
        '      "options": {' \
        '        "apiKey": "{env:OPENCODE_API_KEY}"' \
        '      }' \
        '    }' \
        '  },' \
        '  "statusLine": {' \
        '    "type": "command",' \
        '    "command": "sh /home/agent/.local/bin/statusline-command.sh"' \
        '  }' \
        '}' > /etc/opencode/opencode.json
USER agent

COPY --chown=agent:agent statusline-command.sh /home/agent/.local/bin/statusline-command.sh
RUN chmod +x /home/agent/.local/bin/statusline-command.sh

# Install the latest .NET 10 SDK
RUN curl -sSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh \
    && chmod +x /tmp/dotnet-install.sh \
    && /tmp/dotnet-install.sh --channel 10.0 \
    && rm /tmp/dotnet-install.sh

# Install the latest Swift 6.x toolchain via swiftly (the official installer).
# The base image is Ubuntu 26.04 (resolute), which swiftly does not recognize
# yet, so the platform is pinned to ubuntu24.04: the noble toolchain runs fine
# on resolute once the apt deps above (incl. swiftly's own recommendation of
# libgcc-13-dev libpython3-dev libstdc++-13-dev) are present. Verified 2026-09:
# `swiftly init` pulls Swift 6.4.0 and `swift --version` works in the image.
# swiftly is version-pinned for reproducible builds; the toolchain itself
# floats to latest stable 6.x — rebuild with a new tag to pick up releases.
# swiftly must be >= 1.1.4: earlier versions drop the patch component when
# building the download URL (requesting swift-6.4-RELEASE), which 404s against
# Swift 6.4.0's swift-6.4.0-RELEASE naming (swiftlang/swiftly#592).
ARG SWIFTLY_VERSION=1.1.4
RUN curl -sSL "https://download.swift.org/swiftly/linux/swiftly-${SWIFTLY_VERSION}-$(uname -m).tar.gz" -o /tmp/swiftly.tar.gz \
    && tar -zxf /tmp/swiftly.tar.gz -C /tmp \
    && /tmp/swiftly init --platform ubuntu24.04 --assume-yes --quiet-shell-followup \
    && rm -f /tmp/swiftly.tar.gz /tmp/swiftly

# One merged PATH for both toolchains: .dotnet first (matches opencode/dotnet/Dockerfile),
# then the swiftly shims (swift/swiftc/sourcekit-lsp/lldb/…), then ~/.local/bin
# (home of statusline-command.sh, matches opencode/swift/Dockerfile).
ENV DOTNET_ROOT=/home/agent/.dotnet
ENV PATH="/home/agent/.dotnet:/home/agent/.dotnet/tools:/home/agent/.local/share/swiftly/bin:/home/agent/.local/bin:${PATH}"

# Install .NET global tools
RUN dotnet tool install --global csharp-ls --version 0.24.0 \
    && dotnet tool install --global dotnet-ef --version 10.0.11 \
    && dotnet tool install --global ilspycmd --version 10.1.0.8386 \
    && dotnet tool install --global microsoft.artifacts.credentialprovider.nuget.tool --version 2.0.4 \
    && dotnet tool install --global nswag.consolecore --version 14.7.1 \
    && dotnet tool install --global roslyn-language-server --version 5.9.0-1.26303.1

# Smoke-test the toolchain (fails the build if swift can't run on this base;
# `swift package` exercises the libxml2.so.2 compat lib from above).
RUN swift --version && swift package --version && command -v sourcekit-lsp lldb

# Pre-warm the superpowers + context7 plugin caches so new sandboxes start with
# skills ready and no download. Falls back gracefully: the managed config above
# re-declares the plugins, so even a cold cache self-installs automatically
# on first opencode start (needs github.com + npm registry network then).
RUN command -v opencode >/dev/null \
    && { opencode plugin "superpowers@git+https://github.com/obra/superpowers.git" -g \
        && opencode plugin "@upstash/context7-opencode" -g \
        || echo "WARNING: plugin pre-warm failed; first sandbox start will install missing plugins instead."; } \
    || { echo "ERROR: opencode binary missing from base image."; exit 1; }

# sandboxd starts a Docker daemon inside the sandbox when this label is set.
# Inherited from the opencode-docker base; re-declared so the requirement is explicit.
LABEL com.docker.sandboxes.start-docker=true
