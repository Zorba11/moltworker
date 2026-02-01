#!/bin/bash
# Startup script for Moltbot in Cloudflare Sandbox (v30)
# This script:
# 1. Restores config + workspace from R2 backup if available
# 2. Configures moltbot from environment variables
# 3. Starts the gateway
#
# NOTE: No "set -e" — restore/config steps are best-effort.
# If they fail, the gateway should still start with defaults.

set -x

# Check if clawdbot gateway is already running - bail early if so
# Note: CLI is still named "clawdbot" until upstream renames it
if pgrep -f "clawdbot gateway" > /dev/null 2>&1; then
    echo "Moltbot gateway is already running, exiting."
    exit 0
fi

# Paths — openclaw@2026.1.30 uses ~/.openclaw/openclaw.json
# We symlink the old clawdbot path for backward compat with R2 backups
CONFIG_DIR="/root/.openclaw"
CONFIG_FILE="$CONFIG_DIR/openclaw.json"
LEGACY_CONFIG_DIR="/root/.clawdbot"
TEMPLATE_DIR="/root/.clawdbot-templates"
TEMPLATE_FILE="$TEMPLATE_DIR/moltbot.json.template"
BACKUP_DIR="/data/moltbot"

echo "Config directory: $CONFIG_DIR"
echo "Backup directory: $BACKUP_DIR"

# Create config directory and symlink legacy path
mkdir -p "$CONFIG_DIR"
if [ ! -L "$LEGACY_CONFIG_DIR" ] && [ ! -d "$LEGACY_CONFIG_DIR" ]; then
    ln -s "$CONFIG_DIR" "$LEGACY_CONFIG_DIR"
elif [ -d "$LEGACY_CONFIG_DIR" ] && [ ! -L "$LEGACY_CONFIG_DIR" ]; then
    # Migrate existing clawdbot config to new path
    cp -a "$LEGACY_CONFIG_DIR/." "$CONFIG_DIR/" 2>/dev/null || true
    rm -rf "$LEGACY_CONFIG_DIR"
    ln -s "$CONFIG_DIR" "$LEGACY_CONFIG_DIR"
fi

# ============================================================
# RESTORE FROM R2 BACKUP
# ============================================================
# Check if R2 backup exists by looking for clawdbot.json
# The BACKUP_DIR may exist but be empty if R2 was just mounted
# Note: backup structure is $BACKUP_DIR/clawdbot/ and $BACKUP_DIR/workspace/

# Helper function to check if R2 backup is newer than local
should_restore_from_r2() {
    local R2_SYNC_FILE="$BACKUP_DIR/.last-sync"
    local LOCAL_SYNC_FILE="$CONFIG_DIR/.last-sync"

    # If no R2 sync timestamp, don't restore
    if [ ! -f "$R2_SYNC_FILE" ]; then
        echo "No R2 sync timestamp found, skipping restore"
        return 1
    fi

    # If no local sync timestamp, restore from R2
    if [ ! -f "$LOCAL_SYNC_FILE" ]; then
        echo "No local sync timestamp, will restore from R2"
        return 0
    fi

    # Compare file modification times (portable, no date -d needed)
    # s3fs-mounted files may not have real timestamps, so -nt is safer
    # than trying to parse the file contents with date -d
    if [ "$R2_SYNC_FILE" -nt "$LOCAL_SYNC_FILE" ]; then
        echo "R2 backup is newer, will restore"
        return 0
    else
        echo "Local data is newer or same, skipping restore"
        return 1
    fi
}

if [ -f "$BACKUP_DIR/clawdbot/clawdbot.json" ]; then
    if should_restore_from_r2; then
        echo "Restoring from R2 backup at $BACKUP_DIR/clawdbot..."
        cp -a "$BACKUP_DIR/clawdbot/." "$CONFIG_DIR/"
        # Rename clawdbot.json -> openclaw.json if needed
        if [ -f "$CONFIG_DIR/clawdbot.json" ] && [ ! -f "$CONFIG_DIR/openclaw.json" ]; then
            mv "$CONFIG_DIR/clawdbot.json" "$CONFIG_DIR/openclaw.json"
        fi
        # Copy the sync timestamp to local so we know what version we have
        cp -f "$BACKUP_DIR/.last-sync" "$CONFIG_DIR/.last-sync" 2>/dev/null || true
        echo "Restored config from R2 backup"
    fi
elif [ -f "$BACKUP_DIR/clawdbot.json" ]; then
    # Legacy backup format (flat structure)
    if should_restore_from_r2; then
        echo "Restoring from legacy R2 backup at $BACKUP_DIR..."
        cp -a "$BACKUP_DIR/." "$CONFIG_DIR/"
        cp -f "$BACKUP_DIR/.last-sync" "$CONFIG_DIR/.last-sync" 2>/dev/null || true
        echo "Restored config from legacy R2 backup"
    fi
elif [ -d "$BACKUP_DIR" ]; then
    echo "R2 mounted at $BACKUP_DIR but no backup data found yet"
else
    echo "R2 not mounted, starting fresh"
fi

# Restore full workspace from R2 backup if available
WORKSPACE_DIR="/root/clawd"
if [ -d "$BACKUP_DIR/workspace" ] && [ "$(ls -A $BACKUP_DIR/workspace 2>/dev/null)" ]; then
    if should_restore_from_r2; then
        echo "Restoring workspace from $BACKUP_DIR/workspace..."
        mkdir -p "$WORKSPACE_DIR"
        cp -a "$BACKUP_DIR/workspace/." "$WORKSPACE_DIR/"
        echo "Restored workspace from R2 backup"
    fi
elif [ -d "$BACKUP_DIR/skills" ] && [ "$(ls -A $BACKUP_DIR/skills 2>/dev/null)" ]; then
    # Legacy: skills-only backup format
    if should_restore_from_r2; then
        echo "Restoring skills from $BACKUP_DIR/skills... (legacy format)"
        mkdir -p "$WORKSPACE_DIR/skills"
        cp -a "$BACKUP_DIR/skills/." "$WORKSPACE_DIR/skills/"
        echo "Restored skills from R2 backup (legacy)"
    fi
fi

# If config file still doesn't exist, create from template
if [ ! -f "$CONFIG_FILE" ]; then
    echo "No existing config found, initializing from template..."
    if [ -f "$TEMPLATE_FILE" ]; then
        cp "$TEMPLATE_FILE" "$CONFIG_FILE"
    else
        # Create minimal config if template doesn't exist
        cat > "$CONFIG_FILE" << 'EOFCONFIG'
{
  "agents": {
    "defaults": {
      "workspace": "/root/clawd"
    }
  },
  "gateway": {
    "port": 18789,
    "mode": "local"
  }
}
EOFCONFIG
    fi
else
    echo "Using existing config"
fi

# ============================================================
# UPDATE CONFIG FROM ENVIRONMENT VARIABLES
# ============================================================
node << EOFNODE
const fs = require('fs');

const configPath = '/root/.openclaw/openclaw.json';
console.log('Updating config at:', configPath);
let config = {};

try {
    config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
} catch (e) {
    console.log('Starting with empty config');
}

// Ensure nested objects exist
config.agents = config.agents || {};
config.agents.defaults = config.agents.defaults || {};
config.agents.defaults.model = config.agents.defaults.model || {};
config.gateway = config.gateway || {};
config.channels = config.channels || {};

// Clean up any broken anthropic provider config from previous runs
// (older versions didn't include required 'name' field)
if (config.models?.providers?.anthropic?.models) {
    const hasInvalidModels = config.models.providers.anthropic.models.some(m => !m.name);
    if (hasInvalidModels) {
        console.log('Removing broken anthropic provider config (missing model names)');
        delete config.models.providers.anthropic;
    }
}



// Gateway configuration
config.gateway.port = 18789;
config.gateway.mode = 'local';
config.gateway.trustedProxies = ['10.1.0.0'];

// Set gateway token if provided
if (process.env.CLAWDBOT_GATEWAY_TOKEN) {
    config.gateway.auth = config.gateway.auth || {};
    config.gateway.auth.token = process.env.CLAWDBOT_GATEWAY_TOKEN;
}

// Allow insecure auth for dev mode
if (process.env.CLAWDBOT_DEV_MODE === 'true') {
    config.gateway.controlUi = config.gateway.controlUi || {};
    config.gateway.controlUi.allowInsecureAuth = true;
}

// Telegram configuration
if (process.env.TELEGRAM_BOT_TOKEN) {
    config.channels.telegram = config.channels.telegram || {};
    config.channels.telegram.botToken = process.env.TELEGRAM_BOT_TOKEN;
    config.channels.telegram.enabled = true;
    config.channels.telegram.dm = config.channels.telegram.dm || {};
    config.channels.telegram.dmPolicy = process.env.TELEGRAM_DM_POLICY || 'pairing';
}

// Discord configuration
if (process.env.DISCORD_BOT_TOKEN) {
    config.channels.discord = config.channels.discord || {};
    config.channels.discord.token = process.env.DISCORD_BOT_TOKEN;
    delete config.channels.discord.botToken; // Clean up invalid key from old backup
    config.channels.discord.enabled = true;
    config.channels.discord.dm = config.channels.discord.dm || {};
    config.channels.discord.dm.policy = process.env.DISCORD_DM_POLICY || 'pairing';
    delete config.channels.discord.dm.allowFrom; // Clean up invalid key from old deploy
}

// Slack configuration
if (process.env.SLACK_BOT_TOKEN && process.env.SLACK_APP_TOKEN) {
    config.channels.slack = config.channels.slack || {};
    config.channels.slack.botToken = process.env.SLACK_BOT_TOKEN;
    config.channels.slack.appToken = process.env.SLACK_APP_TOKEN;
    config.channels.slack.enabled = true;
}

// ============================================================
// Configure model providers independently based on available API keys
// ============================================================
config.models = config.models || {};
config.models.providers = config.models.providers || {};
config.agents.defaults.models = config.agents.defaults.models || {};

// ---- Provider: Moonshot/Kimi (OpenAI-compatible) ----
if (process.env.MOONSHOT_API_KEY) {
    console.log('Configuring Kimi K2.5 (Moonshot) provider');
    config.models.providers.openai = {
        baseUrl: 'https://api.moonshot.ai/v1',
        api: 'openai-completions',
        apiKey: process.env.MOONSHOT_API_KEY,
        models: [
            { id: 'kimi-k2.5-preview', name: 'Kimi K2.5', contextWindow: 262144 },
        ]
    };
    config.agents.defaults.models['openai/kimi-k2.5-preview'] = { alias: 'Kimi K2.5' };
}

// ---- Provider: Anthropic/Claude ----
if (process.env.ANTHROPIC_API_KEY) {
    console.log('Configuring Anthropic/Claude provider');
    config.models.providers.anthropic = {
        baseUrl: process.env.ANTHROPIC_BASE_URL || 'https://api.anthropic.com',
        api: 'anthropic-messages',
        apiKey: process.env.ANTHROPIC_API_KEY,
        models: [
            { id: 'claude-opus-4-5-20251101', name: 'Claude Opus 4.5', contextWindow: 200000 },
            { id: 'claude-sonnet-4-5-20250929', name: 'Claude Sonnet 4.5', contextWindow: 200000 },
        ]
    };
    config.agents.defaults.models['anthropic/claude-opus-4-5-20251101'] = { alias: 'Opus 4.5' };
    config.agents.defaults.models['anthropic/claude-sonnet-4-5-20250929'] = { alias: 'Sonnet 4.5' };
}

// ---- Fallback: AI Gateway / OpenAI provider (for Cloudflare AI Gateway users) ----
const baseUrl = (process.env.AI_GATEWAY_BASE_URL || process.env.ANTHROPIC_BASE_URL || '').replace(/\/+$/, '');
const isOpenAI = baseUrl.endsWith('/openai');

if (baseUrl && isOpenAI && !config.models.providers.openai) {
    console.log('Configuring OpenAI provider via AI Gateway:', baseUrl);
    config.models.providers.openai = {
        baseUrl: baseUrl,
        api: 'openai-responses',
        models: [
            { id: 'gpt-5.2', name: 'GPT-5.2', contextWindow: 200000 },
            { id: 'gpt-5', name: 'GPT-5', contextWindow: 200000 },
        ]
    };
    config.agents.defaults.models['openai/gpt-5.2'] = { alias: 'GPT-5.2' };
    config.agents.defaults.models['openai/gpt-5'] = { alias: 'GPT-5' };
} else if (baseUrl && !isOpenAI && !config.models.providers.anthropic) {
    console.log('Configuring Anthropic provider via AI Gateway:', baseUrl);
    const providerConfig = {
        baseUrl: baseUrl,
        api: 'anthropic-messages',
        models: [
            { id: 'claude-opus-4-5-20251101', name: 'Claude Opus 4.5', contextWindow: 200000 },
            { id: 'claude-sonnet-4-5-20250929', name: 'Claude Sonnet 4.5', contextWindow: 200000 },
        ]
    };
    if (process.env.ANTHROPIC_API_KEY) {
        providerConfig.apiKey = process.env.ANTHROPIC_API_KEY;
    }
    config.models.providers.anthropic = providerConfig;
    config.agents.defaults.models['anthropic/claude-opus-4-5-20251101'] = { alias: 'Opus 4.5' };
    config.agents.defaults.models['anthropic/claude-sonnet-4-5-20250929'] = { alias: 'Sonnet 4.5' };
}

// ---- Set primary model (prefer Kimi as default — cheaper) ----
if (process.env.MOONSHOT_API_KEY) {
    config.agents.defaults.model.primary = 'openai/kimi-k2.5-preview';
} else if (process.env.ANTHROPIC_API_KEY) {
    config.agents.defaults.model.primary = 'anthropic/claude-opus-4-5-20251101';
} else if (baseUrl && isOpenAI) {
    config.agents.defaults.model.primary = 'openai/gpt-5.2';
} else if (baseUrl) {
    config.agents.defaults.model.primary = 'anthropic/claude-opus-4-5-20251101';
} else {
    config.agents.defaults.model.primary = 'anthropic/claude-opus-4-5';
}

// Write updated config
fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
console.log('Configuration updated successfully');
console.log('Config:', JSON.stringify(config, null, 2));
EOFNODE

# ============================================================
# START GATEWAY
# ============================================================
# Note: R2 backup sync is handled by the Worker's cron trigger
echo "Starting Moltbot Gateway..."
echo "Gateway will be available on port 18789"

# Clean up stale lock files
rm -f /tmp/clawdbot-gateway.lock 2>/dev/null || true
rm -f "$CONFIG_DIR/gateway.lock" 2>/dev/null || true

BIND_MODE="lan"
echo "Dev mode: ${CLAWDBOT_DEV_MODE:-false}, Bind mode: $BIND_MODE"

# Run gateway with output capture (no exec) so we can log the crash reason
GATEWAY_LOG="/tmp/gateway.log"
echo "=== Gateway starting at $(date -Iseconds) ===" > "$GATEWAY_LOG"

if [ -n "$CLAWDBOT_GATEWAY_TOKEN" ]; then
    echo "Starting gateway with token auth..."
    clawdbot gateway --port 18789 --verbose --allow-unconfigured --bind "$BIND_MODE" --token "$CLAWDBOT_GATEWAY_TOKEN" >> "$GATEWAY_LOG" 2>&1
else
    echo "Starting gateway with device pairing (no token)..."
    clawdbot gateway --port 18789 --verbose --allow-unconfigured --bind "$BIND_MODE" >> "$GATEWAY_LOG" 2>&1
fi

GATEWAY_EXIT=$?
echo "=== Gateway exited with code $GATEWAY_EXIT at $(date -Iseconds) ===" >> "$GATEWAY_LOG"
echo "=== Last 50 lines of gateway output ===" >&2
tail -50 "$GATEWAY_LOG" >&2
exit $GATEWAY_EXIT
