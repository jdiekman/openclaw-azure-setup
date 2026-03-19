# OpenClaw Agent Deployment Log

This document captures every step executed during the deployment of the Accelerate Tech AI Agent ("Zac Smith"). It is intended to be converted into a repeatable skill/runbook.

---

## Prerequisites

- Azure CLI installed and authenticated
- M365 CLI (`m365`) installed and authenticated
- Azure subscription with sufficient quota in Australia East
- Entra ID Global Admin or equivalent access
- GoDaddy DNS access for `<COMPANY_DOMAIN>`
- Spare M365 E3 license
- Anthropic API key

## Identifiers & Credentials

| Item | Value |
|---|---|
| **Subscription** | `<SUBSCRIPTION_NAME>` (`<SUBSCRIPTION_ID>`) |
| **Tenant ID** | `<TENANT_ID>` |
| **Resource Group** | `rg-ai-agent-prod` |
| **VM Name** | `vm-openclaw-agent` |
| **VM Public IP** | `<VM_PUBLIC_IP>` |
| **VM Admin User** | `azureagent` |
| **VM SSH Key** | `~/.ssh/id_rsa` |
| **Agent Linux User** | `ai-agent` (uid 1001) |
| **Agent UPN** | `<AGENT_EMAIL>` |
| **Agent Display Name** | `Zac Smith [Agent]` |
| **Agent Object ID** | `<AGENT_OBJECT_ID>` |
| **Agent Password** | `[REDACTED — rotate and store in Key Vault]` |
| **App Registration Name** | `OpenClaw Agent API` |
| **App (Client) ID** | `<APP_CLIENT_ID>` |
| **App Object ID** | `<APP_OBJECT_ID>` |
| **Service Principal ID** | `<SERVICE_PRINCIPAL_ID>` |
| **Client Secret** | `[REDACTED — rotate and store in Key Vault]` (6-month expiry) |
| **SharePoint Site URL** | `https://<SHAREPOINT_DOMAIN>/sites/ai-agent` |
| **SharePoint Site ID** | `<SHAREPOINT_SITE_ID>` |
| **SharePoint Group ID** | `<SHAREPOINT_GROUP_ID>` |
| **Bot Name** | `bot-openclaw-agent` |
| **Bot Endpoint** | `https://<AGENT_DOMAIN>/api/messages` |
| **Teams Team Name** | `Accelerate AI Agent` |
| **Teams Team ID** | `<TEAMS_TEAM_ID>` |
| **Domain** | `<AGENT_DOMAIN>` |
| **User UPN** | `<USER_EMAIL>` |
| **User Object ID** | `<USER_OBJECT_ID>` |

---

## Phase 1: Azure Resource Group & VM

### 1.1 Set subscription
```bash
az account set --subscription "<SUBSCRIPTION_ID>"
```

### 1.2 Create resource group
```bash
az group create --name rg-ai-agent-prod --location australiaeast \
  --tags project=ai-agent environment=poc owner=<USER_TAG>
```

### 1.3 Create VM
```bash
az vm create \
  --resource-group rg-ai-agent-prod \
  --name vm-openclaw-agent \
  --image Canonical:ubuntu-24_04-lts:server:latest \
  --size Standard_B2ms \
  --admin-username azureagent \
  --generate-ssh-keys \
  --public-ip-address pip-openclaw-agent \
  --public-ip-address-allocation static \
  --public-ip-sku Standard \
  --os-disk-size-gb 64 \
  --storage-sku Premium_LRS \
  --tags project=ai-agent environment=poc owner=<USER_TAG>
```

### 1.4 Lock down NSG
```bash
# Get current public IP
MY_IP=$(curl -s https://ifconfig.me)

# Restrict SSH to current IP only
az network nsg rule update \
  --resource-group rg-ai-agent-prod \
  --nsg-name vm-openclaw-agentNSG \
  --name default-allow-ssh \
  --source-address-prefixes "$MY_IP/32"

# Allow HTTPS inbound
az network nsg rule create \
  --resource-group rg-ai-agent-prod \
  --nsg-name vm-openclaw-agentNSG \
  --name allow-https \
  --priority 1010 \
  --direction Inbound \
  --access Allow \
  --protocol Tcp \
  --destination-port-ranges 443 \
  --source-address-prefixes '*'
```

### 1.5 Enable boot diagnostics
```bash
az vm boot-diagnostics enable \
  --resource-group rg-ai-agent-prod \
  --name vm-openclaw-agent
```

**Estimated cost**: ~$104 AUD/month (VM + disk + static IP)

---

## Phase 2: VM Base Configuration

SSH connection: `ssh azureagent@<VM_PUBLIC_IP>`

### 2.1 System updates & prerequisites
```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl git build-essential unzip jq
```

### 2.2 Install Node.js 22 LTS
```bash
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt install -y nodejs
# Verified: v22.22.0 / npm 10.9.4
```

### 2.3 Install headless Chromium
```bash
sudo apt install -y chromium-browser
# Installed via snap: Chromium 145.0.7632.109
```

### 2.4 Install PM2
```bash
sudo npm install -g pm2
# Verified: 6.0.14
```

### 2.5 Create dedicated agent user
```bash
sudo useradd -m -s /bin/bash ai-agent
```

### 2.6 Install Caddy
```bash
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update
sudo apt install caddy
# Verified: v2.11.1
```

### 2.7 Reboot for kernel upgrade
```bash
sudo reboot
# Kernel updated: 6.14.0-1017-azure -> 6.17.0-1008-azure
```

---

## Phase 3: Entra ID — Agent User Account

### 3.1 Create user
```bash
az ad user create \
  --display-name "Zac Smith [Agent]" \
  --user-principal-name "<AGENT_EMAIL>" \
  --password "<generated>" \
  --force-change-password-next-sign-in false
```

Note: UPN was initially `<AGENT_EMAIL_OLD>`, renamed to `<AGENT_EMAIL_V2>`, then to `<AGENT_EMAIL>`. Set display name, givenName, surname via PATCH.

### 3.2 Set usage location
```bash
az rest --method PATCH \
  --url "https://graph.microsoft.com/v1.0/users/<agent-object-id>" \
  --body '{"usageLocation": "AU"}'
```

### 3.3 Assign M365 E3 license
```bash
az rest --method POST \
  --url "https://graph.microsoft.com/v1.0/users/<agent-object-id>/assignLicense" \
  --body '{"addLicenses": [{"skuId": "<M365_E3_SKU_ID>", "disabledPlans": []}], "removeLicenses": []}'
```

SKU `<M365_E3_SKU_ID>` = SPE_E3 (Microsoft 365 E3).

### 3.4 MFA exclusion
Added agent Object ID to the `excludeUsers` list of the existing `MFA-All-Users` Conditional Access policy (`<MFA_POLICY_ID>`).

```bash
az rest --method PATCH \
  --url "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies/<mfa-policy-id>" \
  --body '{"conditions":{"users":{"includeUsers":["All"],"excludeUsers":["<existing-ids>","<agent-object-id>"]}}}'
```

---

## Phase 4: Entra ID — App Registration

### 4.1 Register the app
```bash
az ad app create \
  --display-name "OpenClaw Agent API" \
  --sign-in-audience AzureADMyOrg
```

### 4.2 Create client secret (6-month expiry)
```bash
az ad app credential reset \
  --id "<app-object-id>" \
  --append \
  --display-name "OpenClaw Agent Secret" \
  --end-date "$(date -d '+6 months' +%Y-%m-%d)"
```

### 4.3 Create service principal
```bash
az ad sp create --id "<app-client-id>"
```

### 4.4 Configure Graph API permissions
Added 8 application (Role) permissions to Microsoft Graph (`00000003-0000-0000-c000-000000000000`):

| Permission | ID |
|---|---|
| Mail.Read | `810c84a8-4a9e-49e6-bf7d-12d183f40d01` |
| Calendars.Read | `798ee544-9d2d-430c-a058-570e29e34338` |
| Sites.Read.All | `332a536c-c7ef-4017-ab91-336970924f0d` |
| Sites.ReadWrite.All | `9492366f-7969-46a4-8d15-ed1a20078fff` |
| ChannelMessage.Read.All | `7b2449af-6ccd-4f4d-9f78-e550c193f0d1` |
| User.Read.All | `df021288-bdef-4463-88db-98f22de89214` |
| OnlineMeetings.Read.All | `c1684f21-1984-47fa-9d61-2dc8c296bb70` |
| Files.Read.All | `01d4889c-1287-42c6-ac1f-5d1e02578ef6` |

Note: `ChannelMessage.Send` does not exist as an application permission — Teams messaging handled via Bot Framework.

### 4.5 Grant admin consent
```bash
GRAPH_SP_ID=$(az rest --method GET \
  --url 'https://graph.microsoft.com/v1.0/servicePrincipals?$filter=appId%20eq%20%2700000003-0000-0000-c000-000000000000%27' \
  --query "value[0].id" --output tsv)

for ROLE_ID in <all-8-permission-ids>; do
  az rest --method POST \
    --url "https://graph.microsoft.com/v1.0/servicePrincipals/<app-sp-id>/appRoleAssignments" \
    --body '{"principalId":"<app-sp-id>","resourceId":"'$GRAPH_SP_ID'","appRoleId":"'$ROLE_ID'"}'
done
```

### 4.6 Mail scoping
**Skipped** — agent reads its own mailbox (`<AGENT_EMAIL>`), not the user's. No ApplicationAccessPolicy needed.

---

## Phase 5: SharePoint Shared Workspace

### 5.1 Create SharePoint site
```bash
m365 spo site add \
  --type TeamSite \
  --title "AI Agent Workspace" \
  --alias "ai-agent" \
  --owners "<USER_EMAIL>"
```

Result: `https://<SHAREPOINT_DOMAIN>/sites/ai-agent`

### 5.2 Lock down access
```bash
# Disable external sharing
m365 spo site set \
  --url "https://<SHAREPOINT_DOMAIN>/sites/ai-agent" \
  --sharingCapability Disabled

# Add Zac to the M365 group (group is already Private)
az rest --method POST \
  --url 'https://graph.microsoft.com/v1.0/groups/<sharepoint-group-id>/members/$ref' \
  --body '{"@odata.id": "https://graph.microsoft.com/v1.0/directoryObjects/<agent-object-id>"}'
```

Members: the user (owner) + Zac (member). No external sharing.

### 5.3 Create document libraries
```bash
for LIB in Inbox Outbox Reference Projects; do
  m365 spo list add \
    --webUrl "https://<SHAREPOINT_DOMAIN>/sites/ai-agent" \
    --title "$LIB" \
    --baseTemplate DocumentLibrary
done
```

---

## Phase 6: Azure Bot Registration

### 6.1 Register resource provider
```bash
az provider register --namespace Microsoft.BotService --wait
```

### 6.2 Create bot resource
```bash
az rest --method PUT \
  --url "https://management.azure.com/subscriptions/<SUBSCRIPTION_ID>/resourceGroups/rg-ai-agent-prod/providers/Microsoft.BotService/botServices/bot-openclaw-agent?api-version=2022-09-15" \
  --body '{
    "location": "global",
    "sku": {"name": "F0"},
    "kind": "azurebot",
    "tags": {"project": "ai-agent", "environment": "poc", "owner": "<USER_TAG>"},
    "properties": {
      "displayName": "Zac Smith [Agent]",
      "endpoint": "https://<AGENT_DOMAIN>/api/messages",
      "msaAppId": "<app-client-id>",
      "msaAppTenantId": "<tenant-id>",
      "msaAppType": "SingleTenant"
    }
  }'
```

### 6.3 Enable Teams channel
```bash
az rest --method PUT \
  --url "https://management.azure.com/subscriptions/<SUBSCRIPTION_ID>/resourceGroups/rg-ai-agent-prod/providers/Microsoft.BotService/botServices/bot-openclaw-agent/channels/MsTeamsChannel?api-version=2022-09-15" \
  --body '{
    "location": "global",
    "properties": {
      "channelName": "MsTeamsChannel",
      "properties": {"isEnabled": true}
    }
  }'
```

---

## Phase 7: DNS & SSL

### 7.1 DNS record (GoDaddy)
Created A record in GoDaddy for `<COMPANY_DOMAIN>`:

| Type | Name | Value | TTL |
|---|---|---|---|
| A | agent | <VM_PUBLIC_IP> | 600 |

### 7.2 Configure Caddy
```bash
sudo tee /etc/caddy/Caddyfile > /dev/null << 'EOF'
<AGENT_DOMAIN> {
    reverse_proxy localhost:3000
}
EOF
sudo systemctl restart caddy
```

SSL certificate auto-provisioned by Let's Encrypt via Caddy.

---

## Phase 8: OpenClaw Installation

### 8.1 Install OpenClaw
```bash
sudo su - ai-agent
curl -fsSL https://openclaw.ai/install.sh | bash
# Installed: v2026.2.26
# Add to PATH: echo 'export PATH="/home/ai-agent/.npm-global/bin:$PATH"' >> ~/.bashrc
```

### 8.2 Run onboard
```bash
openclaw onboard --non-interactive --accept-risk --install-daemon
```

Note: systemd user services unavailable for `ai-agent` user — use PM2 instead.

### 8.3 Configure OpenClaw
Used `openclaw config set` for valid config keys:
```bash
openclaw config set gateway.mode local
openclaw config set gateway.port 3000
openclaw config set agents.defaults.model claude-sonnet-4-6
openclaw config set agents.defaults.memorySearch.enabled false
openclaw config set gateway.controlUi.allowedOrigins.[0] https://<AGENT_DOMAIN>
```

### 8.4 Install Teams plugin
```bash
openclaw plugins install @openclaw/msteams
```

Note: Remove bundled duplicate to avoid warnings:
```bash
rm -rf /home/ai-agent/.npm-global/lib/node_modules/openclaw/extensions/msteams
```

### 8.5 Add Teams channel
```bash
openclaw channels add \
  --channel msteams \
  --name "Zac Smith" \
  --app-token "<app-client-id>" \
  --token "<client-secret>"
```

### 8.6 Write soul.md
Placed at `/home/ai-agent/.openclaw/workspace/soul.md` with identity, behaviour rules, capabilities, tech stack preferences, and restrictions.

### 8.7 Write .env
Placed at `/home/ai-agent/workspace/.env` (chmod 600) with:
- `ANTHROPIC_API_KEY`
- `AZURE_TENANT_ID`, `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`
- `SHAREPOINT_SITE_ID`
- `BOT_APP_ID`, `BOT_APP_SECRET`, `BOT_TENANT_ID`

### 8.8 Start with PM2
Created wrapper script at `/home/ai-agent/start-openclaw.sh`:
```bash
#!/bin/bash
export ANTHROPIC_API_KEY="<key>"
export PATH="/home/ai-agent/.npm-global/bin:$PATH"
exec openclaw gateway run --bind loopback
```

```bash
pm2 start /home/ai-agent/start-openclaw.sh --name openclaw --interpreter bash
pm2 save
```

### 8.9 PM2 auto-start on boot
```bash
sudo env PATH=$PATH:/usr/bin pm2 startup systemd -u ai-agent --hp /home/ai-agent
```

### Key learnings
- `gateway run` (foreground) is the correct command for PM2, not `gateway start` (systemd)
- `--bind loopback` is correct since Caddy handles external traffic
- PM2 ecosystem config files don't reliably pass `args` via `sudo su` — use a wrapper script instead
- The Windows PATH leaks into SSH sessions from Git Bash — use full binary paths when running commands via `sudo su - ai-agent`
- Gateway listens on `ws://127.0.0.1:3000` (WebSocket, not HTTP — `ss` shows it as `openclaw-gatewa`)
- End-to-end verified: `https://<AGENT_DOMAIN>/` returns HTTP 200

---

## Phase 9: Teams Project Channels

### 9.1 Create the private team
```bash
az rest --method POST \
  --url "https://graph.microsoft.com/v1.0/teams" \
  --body '{
    "template@odata.bind": "https://graph.microsoft.com/v1.0/teamsTemplates('"'"'standard'"'"')",
    "displayName": "Accelerate AI Agent",
    "description": "Private team for AI agent operations",
    "visibility": "private",
    "members": [{
      "@odata.type": "#microsoft.graph.aadUserConversationMember",
      "roles": ["owner"],
      "user@odata.bind": "https://graph.microsoft.com/v1.0/users('"'"'<user-object-id>'"'"')"
    }]
  }'
```

Note: Team creation is async (202). Wait ~15 seconds before querying.
Note: Can only add 1 member at creation time — add others after.

### 9.2 Add Zac as member
```bash
az rest --method POST \
  --url 'https://graph.microsoft.com/v1.0/groups/<team-id>/members/$ref' \
  --body '{"@odata.id": "https://graph.microsoft.com/v1.0/directoryObjects/<agent-object-id>"}'
```

### 9.3 Create channels
```bash
for CHANNEL in internal-ops research deployments agent-log project ideas; do
  az rest --method POST \
    --url "https://graph.microsoft.com/v1.0/teams/<team-id>/channels" \
    --body "{\"displayName\": \"$CHANNEL\", \"membershipType\": \"standard\"}"
done
```

Channels created: General (default), internal-ops, research, deployments, agent-log, project, ideas.

---

## Security Audit

Performed 2026-02-28. Verified the full deployment surface.

### Network

| Layer | Finding | Status |
|---|---|---|
| NSG SSH (port 22) | Restricted to `<SSH_SOURCE_IP>/32` | OK — review if IP changes |
| NSG HTTPS (port 443) | Open to `*` | Required for Bot Framework callbacks |
| OpenClaw gateway | Binds to `127.0.0.1:3000` only | OK — not externally reachable |
| msteams plugin | Binds to `*:3978` (behind Caddy) | OK — JWT-authenticated |
| Caddy reverse proxy | Auto-HTTPS via Let's Encrypt | OK |
| Control UI | HTML shell visible at `https://<AGENT_DOMAIN>/` | Low risk — no data exposed, WebSocket requires auth token |

### Identity & Access

| Item | Finding | Status |
|---|---|---|
| App registration | Single-tenant, no redirect URIs | OK |
| SharePoint site | Private, the user + Zac only | OK |
| Teams team | Private | OK |
| SSH password auth | Disabled | OK |
| `.env` file perms | `600` (owner-only read/write) | OK |
| `ai-agent` home dir | `750` | OK |

### Recommendations (not yet actioned)

- Block Control UI from public access (restrict Caddy to `/api/messages` only for external)
- Review SSH source IP periodically (currently `<SSH_SOURCE_IP>/32`)

---

## Workspace File Overhaul

Updated all OpenClaw workspace files from generic defaults to Accelerate-specific content. Input sources: 5 position descriptions (Principal Consultant, Senior Consultant, Consultant, Data Analyst, Delivery Lead) and Accelerate Tech Brand Guidelines PDF.

All files at `/home/ai-agent/.openclaw/workspace/`:

### SOUL.md
Complete rewrite — Zac as Chief of Staff to the user + Principal Consultant. Includes:
- Role definition (user's force-multiplier + senior consultant)
- Company context (Microsoft Solutions Partner — Data & AI, Australian government focus)
- Behaviour rules (be helpful, have opinions, be resourceful)
- Hard rules (read-only mail/calendar, no ClawHub, PR review required, client data siloed, log actions)
- Tech stack preferences
- Brand voice guidance

### IDENTITY.md
```markdown
- Name: Zac Smith
- Display Name: Zac Smith [Agent]
- Email: <AGENT_EMAIL>
- Creature: AI agent — senior team member who happens to be artificial
- Vibe: Sharp, direct, competent. Dry humour. Gets things done.
- Emoji: ⚡
```

### USER.md
the user's profile — User profile — timezone, preferences (direct, hates fluff, expects proactivity).

### TOOLS.md
Environment-specific configuration:
- Graph API: tenant ID, app name, permissions list
- SharePoint: site host, libraries (Inbox/Outbox/Reference/Projects)
- Teams: team name, channel list, log channel (#agent-log)
- Brand: colours (Navy #19263C, Teal #6BE1B8, Dark #141E1E), accent colours, font (Figtree)

### HEARTBEAT.md
Periodic check schedule: inbox, calendar, SharePoint Inbox, Teams mentions.

### Deleted Files
- `BOOTSTRAP.md` — first-run only, no longer needed
- `soul.md` (lowercase) — NOT a recognized OpenClaw bootstrap file; only uppercase `SOUL.md` auto-loads

### Key learning
All workspace files (`SOUL.md`, `IDENTITY.md`, `USER.md`, `TOOLS.md`, `HEARTBEAT.md`, `AGENTS.md`) are injected into **every** system prompt turn. Keep them concise to manage token costs.

---

## Teams Bot Integration

### OpenClaw Configuration Updates

#### `openclaw.json` — Bot credentials
Added bot credentials to `channels.msteams`:
```json
{
  "channels": {
    "msteams": {
      "enabled": true,
      "dmPolicy": "open",
      "groupPolicy": "open",
      "allowFrom": ["*"],
      "groupAllowFrom": ["*"],
      "appId": "<APP_CLIENT_ID>",
      "appPassword": "<client-secret>",
      "tenantId": "<TENANT_ID>"
    }
  }
}
```

**Key learnings:**
- msteams plugin reads credentials from `channels.msteams.appId`, `appPassword`, `tenantId` in `openclaw.json` (or env vars `MSTEAMS_APP_ID`, `MSTEAMS_APP_PASSWORD`, `MSTEAMS_TENANT_ID`)
- `dmPolicy: "open"` requires `allowFrom: ["*"]` — OpenClaw enforces this at startup
- `groupPolicy: "open"` requires `groupAllowFrom: ["*"]`
- Initial `dmPolicy: "pairing"` caused all DMs to be silently dropped with log message `dropping dm (not allowlisted)`

#### `openclaw.json` — Model name
Changed model from `claude-sonnet-4-6` to `anthropic/claude-sonnet-4-6` (provider prefix required).

#### `start-openclaw.sh` — Environment variables
Updated wrapper script to source all env vars from `.env`:
```bash
#!/bin/bash
set -a
source /home/ai-agent/workspace/.env
set +a
export PATH="/home/ai-agent/.npm-global/bin:$PATH"
exec openclaw gateway run --bind loopback
```

Previous version only exported `ANTHROPIC_API_KEY`.

### Caddy Routing

Updated `/etc/caddy/Caddyfile` to route Bot Framework webhook traffic to the msteams plugin:
```
<AGENT_DOMAIN> {
    handle /api/messages {
        reverse_proxy localhost:3978
    }
    handle {
        reverse_proxy localhost:3000
    }
}
```

**Key learning:** The msteams plugin runs a **separate** Express HTTP server on port 3978 (not the OpenClaw gateway on port 3000). Bot Framework POSTs to `/api/messages` must reach port 3978, not 3000.

### msteams Plugin Crash Loop Fix

**Symptom:** msteams plugin entered auto-restart cycle immediately after starting. Logs showed `starting provider (port 3978)` then `[default] auto-restart attempt 1/10` within ~50ms. Port 3978 was listening and responding with 401 (correct JWT auth), but the gateway's health monitor kept restarting.

**Root cause:** Bug in `extensions/msteams/src/monitor.ts`. The `monitorMSTeamsProvider()` function returned `{ app, shutdown }` immediately after calling `expressApp.listen()`. The OpenClaw gateway lifecycle expects `startAccount()` to return a **long-lived promise** that stays pending while the provider is running. When the promise resolved immediately, the gateway interpreted it as "provider stopped" and triggered auto-restart. Subsequent restarts hit `EADDRINUSE` because the first server was still bound to port 3978.

**Fix:** Patched `monitor.ts` to wrap the return in a `new Promise()` that only resolves when the HTTP server closes (via abort signal → `shutdown()` → `httpServer.close()` → `close` event), or rejects on server error:

```typescript
// Before (buggy):
return { app: expressApp, shutdown };

// After (fixed):
return new Promise<MonitorMSTeamsResult>((resolve, reject) => {
    const httpServer = expressApp.listen(port, () => {
        log.info(`msteams provider started on port ${port}`);
    });
    // ... shutdown function ...
    httpServer.on("error", (err) => { reject(err); });
    httpServer.on("close", () => { resolve({ app: expressApp, shutdown }); });
    if (opts.abortSignal) {
        opts.abortSignal.addEventListener("abort", () => { void shutdown(); });
    }
});
```

Backup at `extensions/msteams/src/monitor.ts.bak`. Note: this patch must be reapplied if the msteams plugin is updated via `openclaw plugins install`.

### Teams App Manifest

Created Teams app package at `teams-app/zac-smith-bot.zip` containing:

| File | Details |
|---|---|
| `manifest.json` | Schema v1.17, bot-only app, scopes: personal/team/groupchat |
| `color.png` | 192x192 RGBA PNG |
| `outline.png` | 32x32 RGBA PNG with transparent background |

**Manifest key fields:**
```json
{
  "$schema": "https://developer.microsoft.com/json-schemas/teams/v1.17/MicrosoftTeams.schema.json",
  "manifestVersion": "1.17",
  "id": "<APP_CLIENT_ID>",
  "name": { "short": "Zac Smith" },
  "bots": [{
    "botId": "<APP_CLIENT_ID>",
    "scopes": ["personal", "team", "groupchat"]
  }],
  "validDomains": ["<AGENT_DOMAIN>", "token.botframework.com"]
}
```

**Manifest parsing errors encountered and fixed:**
1. `groupChat` → `groupchat` (must be lowercase)
2. Removed `authorization.permissions.resourceSpecific` (unsupported in v1.17)
3. Removed empty `commandLists` array
4. Removed `/en-us/` from schema URL path
5. Changed `accentColor` to `#FFFFFF`
6. Added `token.botframework.com` to `validDomains`
7. Downgraded from schema v1.19 to v1.17

**Deployment:** Uploaded via Teams Admin Center (**Teams apps** > **Manage apps** > **Upload new app**). Sideloading via Teams client failed with "Something went wrong" (likely tenant policy). Admin center upload worked. App appears under "Built for your org" in the Teams client app catalog.

Note: Admin center uploads can take **up to 24 hours** to propagate to the Teams client.

### End-to-End Verification

Tested via Azure Bot Direct Line API:
```
[User]: Hello Zac
[Zac Smith [Agent]]: Morning! How can I help?
```

Bot responds correctly to both Direct Line and Teams (1:1 DM and channel @mention).

---

## Graph Permissions Expansion, Exchange Policy & Profile Picture

Performed 2026-03-01. Added email sending, Teams chat/reactions, calendar access for the user, and Zac's profile picture.

### New Permissions Added

| Permission | GUID | Purpose |
|---|---|---|
| Chat.ReadWrite.All | `294ce7c9-31ba-490a-ad7d-97a7d075e4ed` | Teams reactions (👀 ⚙️ ✅) and richer chat access |
| Mail.Send | `b633e1c5-b582-4048-a93e-9f11b44c7e96` | Send/reply to emails from <AGENT_EMAIL> |

### Permission Removed

| Permission | GUID | Reason |
|---|---|---|
| Files.Read.All | `01d4889c-1287-42c6-ac1f-5d1e02578ef6` | Redundant — superseded by Files.ReadWrite.All |

### Final Permission Set (9 application permissions, all admin-consented)

Mail.Read, Mail.Send, Calendars.Read, Chat.ReadWrite.All, Sites.Read.All, Sites.ReadWrite.All, User.Read.All, OnlineMeetings.Read.All, ChannelMessage.Read.All

### Exchange Application Access Policy

Created mail-enabled security group via Exchange Online PowerShell and applied application access policy:

| Item | Value |
|---|---|
| **Group Name** | AI Agent Mail Access |
| **Group ID** | `<MAIL_GROUP_ID>` |
| **Group Mail** | `<MAIL_GROUP_EMAIL>` |
| **Members** | `<AGENT_EMAIL>`, `<USER_EMAIL>` |

**Key learning**: Exchange Application Access Policies require a **mail-enabled** security group. Plain Azure AD security groups (created via `az ad group create` or Graph API) don't work — Exchange can't resolve them. Must use `New-DistributionGroup -Type Security` in Exchange Online PowerShell.

Commands executed:
```powershell
Install-Module ExchangeOnlineManagement -Scope CurrentUser
Import-Module ExchangeOnlineManagement
Connect-ExchangeOnline  # must run from non-elevated PowerShell (WAM broker fails in admin sessions)

New-DistributionGroup -Name "AI Agent Mail Access" -Type Security -Members "<AGENT_EMAIL>","<USER_EMAIL>"

New-ApplicationAccessPolicy -AppId "<APP_CLIENT_ID>" -PolicyScopeGroupId "AI Agent Mail Access" -AccessRight RestrictAccess -Description "Restrict OpenClaw agent to the agent and the user mailboxes only"
```

**Trade-off**: Exchange application access policies scope by mailbox, not by permission type. The policy allows the app to access both Zac's and the user's mailboxes (needed for Calendars.Read on the user + Mail.Read/Mail.Send on Zac). This means the app can technically read the user's mail too. SOUL.md behavioural rules enforce the restriction.

### Teams Channel Mapping

Added team/channel IDs to `openclaw.json` under `channels.msteams.teams`:

```json
{
  "<TEAMS_TEAM_ID>": {
    "channels": {
      "<CHANNEL_ID_GENERAL>": {},
      "<CHANNEL_ID_RESEARCH>": {},
      "<CHANNEL_ID_INTERNAL_OPS>": {},
      "<CHANNEL_ID_PROJECT>": {},
      "<CHANNEL_ID_AGENT_LOG>": {},
      "<CHANNEL_ID_IDEAS>": {},
      "<CHANNEL_ID_DEPLOYMENTS>": {}
    }
  }
}
```

**Key learning**: OpenClaw's config schema for channel entries does not support a `label` field — channel IDs must map to empty objects `{}`. Channel labels are documented in TOOLS.md instead.

**Note**: On startup, the msteams plugin attempts to resolve channels via `GET /teams/{id}/channels` which requires `Channel.ReadBasic.All` (not currently granted). It falls back to the config entries, which is sufficient. Adding `Channel.ReadBasic.All` would suppress the 403 warning but is not required.

### Workspace File Updates

**SOUL.md** — Updated hard rule:
- Before: "Email and calendar are READ-ONLY — never send, reply, forward, accept, or decline without explicit approval from the user"
- After: "Calendar is READ-ONLY. Email sending is enabled from <AGENT_EMAIL> — always get the user's approval before sending to external recipients. Never send, forward, accept or decline calendar invites without explicit approval."

**TOOLS.md** — Updated:
- Permissions list: added Mail.Send, Chat.ReadWrite.All; removed Files.Read.All
- Mail scope: read own mailbox + send from own address (with approval for external recipients)
- Calendar scope: added read access to the user's calendar (<USER_EMAIL>)
- Chat scope: added Chat.ReadWrite.All for Teams reactions
- Teams: added all 7 channel IDs with labels, proactive posting note
- Team name corrected from "Accelerate Agent Ops" to "Accelerate AI Agent"

### Profile Picture

Uploaded AI-generated profile picture for Zac Smith to Entra ID:
- Source: `Zac_Smith.png` (1024x1536 PNG)
- Processed: center-cropped from top to 1024x1024, resized to 648x648, converted to JPEG
- Uploaded via `PUT /users/{id}/photo/$value` using Graph API

### Teams Bot Icons Updated

Replaced lightning bolt icons with Zac's avatar in `teams-app/`:
- `color.png`: 192x192 — cropped from `Zac_Smith.png` (head/shoulders, top 1024x1024 → resized)
- `outline.png`: 32x32 — white silhouette on transparent background (derived from same crop)
- Rebuilt `zac-smith-bot.zip` with updated icons

**Action required**: Re-upload `zac-smith-bot.zip` via Teams Admin Center (**Teams apps** > **Manage apps** > find "Zac Smith" > **Upload new version**). Icon changes may take up to 24 hours to propagate.

### OpenClaw Restart

Restarted OpenClaw via PM2. Verified stable (no crash loop, gateway listening on ws://127.0.0.1:3000, msteams plugin on port 3978).

---

## Exchange PowerShell Tasks

Performed 2026-03-01 via Exchange Online PowerShell (non-elevated session, ExchangeOnlineManagement v3.9.2).

### Application Access Policy

Restricts the app's mail/calendar access to only Zac's and the user's mailboxes. See "Exchange Application Access Policy" section above for group details and commands.

### Shared Mailbox Access (User → Zac's mailbox)

Granted the user full access to Zac's mailbox in Outlook (auto-maps as additional mailbox):

```powershell
Add-MailboxPermission -Identity "<AGENT_EMAIL>" -User "<USER_EMAIL>" -AccessRights FullAccess -AutoMapping $true
```

Zac's mailbox will auto-appear in the user's Outlook within ~30 minutes (under the folder pane). If it doesn't auto-map, manually add via **File** > **Account Settings** > **Account Settings** > **Change** > **More Settings** > **Advanced** > **Add** > `<AGENT_EMAIL>`.

### Key learnings
- `Connect-ExchangeOnline` fails with WAM broker error in elevated (admin) PowerShell sessions — must run from a **non-elevated** window
- Exchange mail-enabled security groups must be created via `New-DistributionGroup -Type Security`, not via Azure AD / Graph API

---

## Real-Time Teams Meeting Participation (ACS + Speech)

**Status**: Code written, Azure resources not yet provisioned.

### Overview

Meeting sidecar service enabling Zac to join Teams meetings as a live participant — listening to audio, transcribing in real-time, responding via speech (TTS), and posting to meeting chat.

### Architecture

```
Teams Meeting → ACS Call Automation → meeting-service (port 3979, WebSocket)
    ├── Inbound audio → Azure Speech STT → real-time transcript → Claude → response
    └── Outbound audio ← Azure Speech TTS ← response text
    └── Meeting chat ← Graph API (transcript chunks, summaries)
```

### New Azure Resources

| Resource | Name | Purpose | Est. Cost |
|---|---|---|---|
| ACS | `acs-openclaw-agent` | Call Automation + media streaming | ~$0.004/min |
| Azure AI Speech | `speech-openclaw-agent` | Real-time STT + TTS | ~$1/hr STT |

### New Graph Permissions

| Permission | GUID | Purpose |
|---|---|---|
| Calls.JoinGroupCall.All | `f6b49018-60ab-4f81-83bd-22caeabfed2d` | Join Teams meetings programmatically |
| OnlineMeetingTranscript.Read.All | `a4a80d8d-d283-4bd8-8504-555ec3870630` | Read post-meeting transcripts (fallback) |

### Meeting Service Files (repo: `meeting-service/`)

| File | Purpose |
|---|---|
| `src/index.ts` | Express server (port 3979) + WebSocket for ACS audio streaming |
| `src/meeting-manager.ts` | ACS Call Automation — join/leave meetings, call lifecycle |
| `src/audio-pipeline.ts` | Azure Speech SDK — STT (continuous recognition) + TTS |
| `src/transcript.ts` | Transcript accumulation + Claude analysis (every 30s) |
| `src/chat-poster.ts` | Graph API — post to meeting chat and Teams channels |
| `src/config.ts` | Environment variable configuration |
| `scripts/setup-azure.sh` | Creates ACS + Speech resources, adds Graph permissions |
| `scripts/setup-teams-interop.ps1` | Enables ACS-Teams federation (the user runs this) |
| `scripts/verify-audio.ts` | Verification test — join meeting, confirm audio frames arrive |
| `scripts/start-meeting-service.sh` | PM2 wrapper script for VM deployment |
| `scripts/Caddyfile` | Updated Caddy config with meeting service routes |

### VM Files (after deployment)

| Path | Purpose |
|---|---|
| `/home/ai-agent/meeting-service/` | Meeting sidecar service (built from repo) |
| `/home/ai-agent/start-meeting-service.sh` | PM2 wrapper script |

### New Environment Variables (added to `.env`)

```
ACS_CONNECTION_STRING=endpoint=https://acs-openclaw-agent.australia.communication.azure.com/;accesskey=...
ACS_ENDPOINT=https://acs-openclaw-agent.australia.communication.azure.com
SPEECH_KEY=...
SPEECH_REGION=australiaeast
```

### Caddy Update

Added routes for meeting service (port 3979):
- `/api/meeting/*` — meeting join/leave/callbacks API
- `/audio-stream` — ACS media streaming WebSocket

### Execution Checklist

1. [ ] Run `scripts/setup-azure.sh` — create ACS + Speech resources, add Graph permissions
2. [ ] Run `scripts/setup-teams-interop.ps1` (the user — Teams Admin PowerShell)
3. [ ] Admin-consent new permissions in Entra ID portal
4. [ ] Add new env vars to `/home/ai-agent/workspace/.env` on VM
5. [ ] Run `scripts/verify-audio.ts` — confirm ACS can join meeting and receive audio
6. [ ] Deploy meeting service to VM (`npm install && npm run build`)
7. [ ] Update Caddy config on VM (backup existing, apply new Caddyfile)
8. [ ] Start meeting service with PM2 (`start-meeting-service.sh`)
9. [ ] Update SOUL.md + TOOLS.md on VM with meeting behaviour rules
10. [ ] Test with a real Teams meeting

### Key Technical Risk

ACS Call Automation media streaming (bidirectional WebSocket audio) in the Teams meeting context is not fully documented. The verification test (`scripts/verify-audio.ts`) must confirm audio frames arrive before proceeding with full deployment. If audio streaming doesn't work, fall back to headless browser approach (Puppeteer joining Teams web client).

---

## Duplicate Message Fix (Teams)

Performed 2026-03-04. Zac was sending every response twice in Teams DMs and channels.

### Root Cause

Two issues stacking:

1. **Proxy revocation mid-send**: The default `replyStyle: "thread"` uses the original TurnContext from the webhook. When the LLM takes longer than ~15 seconds, Bot Framework sends the HTTP response and revokes the context proxy. If the first message chunk was already sent via the original context, the messenger.ts fallback to `continueConversation()` re-sends everything, producing duplicates.

2. **Webhook retry bypass**: The activity ID dedup only keyed on `req.body.id`. Teams retries can assign new activity IDs and timestamps, bypassing the dedup entirely.

### Fix (3 patches)

**1. `monitor.ts` — Content-based dedup**

Added a second dedup layer using `sender:text` as the key (no timestamp, since retries get new timestamps). Catches retries even when Teams assigns different activity IDs.

```typescript
// Content-based dedup (catches retries where Teams assigns a new activity ID/timestamp)
const senderId = body?.from?.aadObjectId || body?.from?.id || "";
const text = body?.text || "";
const contentKey = `content:${senderId}:${text}`;
if (senderId && seenActivities.has(contentKey)) {
  log.debug?.("skipping duplicate activity (content match)", { id: body?.id, contentKey });
  res.status(200).end();
  return;
}
```

**2. `policy.ts` — DM replyStyle override**

The `resolveMSTeamsReplyPolicy` function hardcoded `replyStyle: "thread"` for DMs, ignoring the config. Patched to respect the global `replyStyle` config:

```typescript
// Before:
if (params.isDirectMessage) {
  return { requireMention: false, replyStyle: "thread" };
}

// After:
if (params.isDirectMessage) {
  const dmReplyStyle = params.globalConfig?.replyStyle;
  return { requireMention: false, replyStyle: dmReplyStyle ?? "thread" };
}
```

**3. `openclaw.json` — replyStyle config**

Set `replyStyle: "top-level"` on the msteams channel config. This forces proactive messaging for all messages (DMs + channels), avoiding the proxy revocation issue entirely since proactive messaging creates a fresh context not tied to the HTTP request lifecycle.

```json
{
  "channels": {
    "msteams": {
      "replyStyle": "top-level"
    }
  }
}
```

### Patched files (must reapply after msteams plugin update)

| File | Patch |
|---|---|
| `extensions/msteams/src/monitor.ts` | Long-lived promise + activity dedup + content-based dedup |
| `extensions/msteams/src/messenger.ts` | Proxy revocation fallback (existing) |
| `extensions/msteams/src/policy.ts` | DM replyStyle config override |

Backups at `.bak` / `.bak2` suffixes.

---

## Phase 10: GitHub Account & Repos

**Status**: Not yet started.

---

## Remaining Steps

- [x] ~~Phase 9.3: Test agent responds to @mention in Teams~~ (verified 2026-03-01)
- [x] ~~End-to-end test: send a message to Zac in Teams~~ (verified 2026-03-01)
- [x] ~~Graph permissions: Chat.ReadWrite.All, Mail.Send added; Files.Read.All removed~~ (2026-03-01)
- [x] ~~Security group "AI Agent Mail Access" created with the agent + the user~~ (2026-03-01)
- [x] ~~Teams channel IDs added to openclaw.json~~ (2026-03-01)
- [x] ~~SOUL.md + TOOLS.md updated for new capabilities~~ (2026-03-01)
- [x] ~~Profile picture uploaded to Entra ID~~ (2026-03-01)
- [x] ~~Teams bot icons updated with Zac avatar~~ (2026-03-02)
- [x] ~~Re-upload `zac-smith-bot.zip` via Teams Admin Center (icon update)~~ (2026-03-02)
- [x] ~~Exchange PowerShell: Application Access Policy + mailbox delegation~~ (2026-03-01)
- [ ] Meeting service: provision ACS + Speech Azure resources
- [ ] Meeting service: enable ACS-Teams interop (Teams Admin PowerShell)
- [ ] Meeting service: run verification test (confirm audio streaming works)
- [ ] Meeting service: deploy to VM + start with PM2
- [ ] Meeting service: update SOUL.md + TOOLS.md with meeting behaviour rules
- [ ] Meeting service: test with real Teams meeting
- [x] ~~Duplicate message fix: content-based dedup + replyStyle top-level + policy.ts DM patch~~ (2026-03-04)
- [ ] Phase 10: GitHub account, SSH keys, template repos, OIDC federation
- [ ] Move secrets from `.env` to Azure Key Vault
- [ ] Block Control UI from public access via Caddy
- [ ] Reapply `monitor.ts` patch after any msteams plugin update
- [ ] Review SSH source IP if home IP changes
- [ ] Set `plugins.allow` in `openclaw.json` to explicitly trust msteams plugin (suppress warning)
- [ ] Add `Channel.ReadBasic.All` permission (optional — suppresses 403 warning on startup)
