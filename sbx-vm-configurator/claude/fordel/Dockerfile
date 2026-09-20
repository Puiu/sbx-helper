FROM docker/sandbox-templates:claude-code-docker
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
# Guarded on the base image's codename: this Dockerfile is built from
# docker/sandbox-templates:claude-code-docker, which was not verified to be
# resolute like the opencode-docker base opencode/swift/Dockerfile targets —
# skip the compat install entirely if the base is already noble (or newer)
# so it doesn't fight the system libs that are already the right version.
RUN . /etc/os-release \
    && if [ "${VERSION_CODENAME:-}" != "noble" ]; then \
        ARCH=$(dpkg --print-architecture) \
        && if [ "$ARCH" = arm64 ]; then MIRROR=http://ports.ubuntu.com/ubuntu-ports; else MIRROR=http://archive.ubuntu.com/ubuntu; fi \
        && echo "deb $MIRROR noble main universe" > /etc/apt/sources.list.d/noble-compat.list \
        && apt-get update \
        && apt-get install -y --no-install-recommends libxml2 libicu74 libpython3.12 \
        && rm /etc/apt/sources.list.d/noble-compat.list \
        && apt-get update; \
    else \
        echo "Base image is already noble; skipping noble-compat shim."; \
    fi

# Wire up the statusline. sbx rewrites /home/agent/.claude/settings.json unconditionally on every
# sandbox (re)create, so user-level settings can't hold this; /etc/claude-code is untouched by sbx
# and loads at Claude Code's highest-precedence (policy) tier.
# The same managed file also pre-registers the superpowers and context7 marketplaces
# and enables both plugins, so no manual install is needed in new sandboxes
# (see pre-install step below).
RUN mkdir -p /etc/claude-code \
    && printf '%s\n' \
        '{' \
        '  "statusLine": {' \
        '    "type": "command",' \
        '    "command": "sh /home/agent/.local/bin/statusline-command.sh"' \
        '  },' \
        '  "extraKnownMarketplaces": {' \
        '    "superpowers-marketplace": {' \
        '      "source": {' \
        '        "source": "github",' \
        '        "repo": "obra/superpowers-marketplace"' \
        '      }' \
        '    },' \
        '    "context7-marketplace": {' \
        '      "source": {' \
        '        "source": "git",' \
        '        "url": "https://github.com/upstash/context7.git"' \
        '      }' \
        '    }' \
        '  },' \
        '  "enabledPlugins": {' \
        '    "superpowers@superpowers-marketplace": true,' \
        '    "context7@context7-marketplace": true' \
        '  }' \
        '}' > /etc/claude-code/managed-settings.json
USER agent

COPY --chown=agent:agent statusline-command.sh /home/agent/.local/bin/statusline-command.sh
RUN chmod +x /home/agent/.local/bin/statusline-command.sh

# Install the latest .NET 10 SDK
RUN curl -sSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh \
    && chmod +x /tmp/dotnet-install.sh \
    && /tmp/dotnet-install.sh --channel 10.0 \
    && rm /tmp/dotnet-install.sh

# Install the latest Swift 6.x toolchain via swiftly (the official installer).
# Pinned to ubuntu24.04 (noble) same as opencode/swift/Dockerfile: swiftly does
# not recognize resolute yet, and the noble toolchain runs fine on resolute
# once the apt deps above (incl. swiftly's own recommendation of
# libgcc-13-dev libpython3-dev libstdc++-13-dev) are present. swiftly is
# version-pinned for reproducible builds; the toolchain itself floats to
# latest stable 6.x — rebuild with a new tag to pick up releases.
ARG SWIFTLY_VERSION=1.1.2
RUN curl -sSL "https://download.swift.org/swiftly/linux/swiftly-${SWIFTLY_VERSION}-$(uname -m).tar.gz" -o /tmp/swiftly.tar.gz \
    && tar -zxf /tmp/swiftly.tar.gz -C /tmp \
    && /tmp/swiftly init --platform ubuntu24.04 --assume-yes --quiet-shell-followup \
    && rm -f /tmp/swiftly.tar.gz /tmp/swiftly

# One merged PATH for both toolchains: .dotnet first (matches claude/dotnet/Dockerfile),
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

# Smoke-test the Swift toolchain (fails the build if swift can't run on this base;
# `swift package` exercises the libxml2.so.2 compat lib from above).
RUN swift --version && swift package --version && command -v sourcekit-lsp lldb

# Pre-install the superpowers + context7 plugins so new sandboxes start with skills ready.
# HTTPS sources (not owner/repo shorthands) so the build needs no SSH keys.
# Failure-tolerant: the managed settings above re-register the marketplaces and
# enable the plugins, so a cold cache only costs one manual
# `claude plugin install <plugin>` inside the sandbox.
RUN command -v claude >/dev/null \
    && { claude plugin marketplace add https://github.com/obra/superpowers-marketplace \
        && claude plugin install "superpowers@superpowers-marketplace" -s user \
        && claude plugin marketplace add https://github.com/upstash/context7 \
        && claude plugin install "context7@context7-marketplace" -s user \
        || echo "WARNING: plugin pre-install failed; install missing plugins manually in the sandbox instead."; } \
    || { echo "ERROR: claude binary missing from base image."; exit 1; }

# sandboxd starts a Docker daemon inside the sandbox when this label is set.
# Inherited from the claude-code-docker base; re-declared so the requirement is explicit.
LABEL com.docker.sandboxes.start-docker=true
