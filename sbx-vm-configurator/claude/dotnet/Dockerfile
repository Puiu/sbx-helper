FROM docker/sandbox-templates:claude-code-docker
USER root
RUN apt-get update && apt-get install -y jq libicu-dev ca-certificates

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

ENV DOTNET_ROOT=/home/agent/.dotnet
ENV PATH="/home/agent/.dotnet:/home/agent/.dotnet/tools:${PATH}"

# Install .NET global tools
RUN dotnet tool install --global csharp-ls --version 0.24.0 \
    && dotnet tool install --global dotnet-ef --version 10.0.11 \
    && dotnet tool install --global ilspycmd --version 10.1.0.8386 \
    && dotnet tool install --global microsoft.artifacts.credentialprovider.nuget.tool --version 2.0.4 \
    && dotnet tool install --global nswag.consolecore --version 14.7.1 \
    && dotnet tool install --global roslyn-language-server --version 5.9.0-1.26303.1

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