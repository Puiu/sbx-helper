FROM docker/sandbox-templates:claude-code-docker
USER root
RUN apt-get update && apt-get install -y jq libicu-dev ca-certificates

# Wire up the statusline. sbx rewrites /home/agent/.claude/settings.json unconditionally on every
# sandbox (re)create, so user-level settings can't hold this; /etc/claude-code is untouched by sbx
# and loads at Claude Code's highest-precedence (policy) tier.
RUN mkdir -p /etc/claude-code \
    && printf '%s\n' \
        '{' \
        '  "statusLine": {' \
        '    "type": "command",' \
        '    "command": "sh /home/agent/.local/bin/statusline-command.sh"' \
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

# sandboxd starts a Docker daemon inside the sandbox when this label is set.
# Inherited from the claude-code-docker base; re-declared so the requirement is explicit.
LABEL com.docker.sandboxes.start-docker=true