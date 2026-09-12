FROM docker/sandbox-templates:opencode-docker
USER root
RUN apt-get update && apt-get install -y jq libicu-dev ca-certificates

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

ENV DOTNET_ROOT=/home/agent/.dotnet
ENV PATH="/home/agent/.dotnet:/home/agent/.dotnet/tools:${PATH}"

# Install .NET global tools
RUN dotnet tool install --global csharp-ls --version 0.24.0 \
    && dotnet tool install --global dotnet-ef --version 10.0.11 \
    && dotnet tool install --global ilspycmd --version 10.1.0.8386 \
    && dotnet tool install --global microsoft.artifacts.credentialprovider.nuget.tool --version 2.0.4 \
    && dotnet tool install --global nswag.consolecore --version 14.7.1 \
    && dotnet tool install --global roslyn-language-server --version 5.9.0-1.26303.1

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
