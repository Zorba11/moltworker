FROM docker.io/cloudflare/sandbox:0.7.0

# Install Node.js 22 (required by clawdbot) and rsync (for R2 backup sync)
# The base image has Node 20, we need to replace it with Node 22
# Using direct binary download for reliability
ENV NODE_VERSION=22.13.1
RUN apt-get update && apt-get install -y xz-utils ca-certificates rsync \
    && curl -fsSLk https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz -o /tmp/node.tar.xz \
    && tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 \
    && rm /tmp/node.tar.xz \
    && node --version \
    && npm --version

# Install pnpm globally
RUN npm install -g pnpm

# Install moltbot gateway (upgraded to openclaw with native Kimi K2.5 support)
# Pin to specific version for reproducible builds
# Symlink clawdbot → openclaw for backward compatibility (start-moltbot.sh, Worker code)
RUN npm install -g openclaw@2026.1.30 \
    && openclaw --version \
    && ln -s /usr/local/bin/openclaw /usr/local/bin/clawdbot

# Create moltbot directories
# openclaw@2026.1.30 uses ~/.openclaw/, symlink legacy ~/.clawdbot/ for R2 backup compat
RUN mkdir -p /root/.openclaw \
    && ln -s /root/.openclaw /root/.clawdbot \
    && mkdir -p /root/.clawdbot-templates \
    && mkdir -p /root/clawd \
    && mkdir -p /root/clawd/skills

# Copy startup script
ARG CACHE_BUST=2026-02-01-v43-fix-anthropic-baseurl
COPY start-moltbot.sh /usr/local/bin/start-moltbot.sh
RUN chmod +x /usr/local/bin/start-moltbot.sh

# Copy default configuration template
COPY moltbot.json.template /root/.clawdbot-templates/moltbot.json.template

# Copy custom skills
COPY skills/ /root/clawd/skills/

# Set working directory
WORKDIR /root/clawd

# Expose the gateway port
EXPOSE 18789
