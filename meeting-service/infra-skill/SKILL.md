---
name: infra-ops
description: Infrastructure operations reference for the OpenClaw agent platform. Use this skill when troubleshooting VM issues, managing services (PM2, Caddy), updating Graph API permissions, deploying code changes, managing Teams integration, or performing any infrastructure maintenance on the agent platform. Also use when the user asks about the current setup, architecture, or how something is configured.
---

# Infrastructure Operations - OpenClaw Agent Platform

This is your operational reference for the Accelerate Tech AI agent infrastructure. Everything you need to manage, troubleshoot, and maintain the platform.

## Architecture Overview

```
User --> Microsoft Teams --> Azure Bot Service --> Caddy (HTTPS :443)
                                                            |
                                     +----------------------+----------------------+
                                     |                      |                      |
                              /api/messages           /api/meeting/*          everything else
                              msteams plugin          meeting-service         OpenClaw gateway
                              port 3978               port 3979 (stopped)     port 3000
                                     |                      |                      |
                              Bot Framework           ACS + Speech          Agent runtime
                              webhook handler         (real-time meetings)   (Claude Sonnet)
                                     |                                             |
                              +------+------+                    +-----------------+----------+
                              |             |                    |                 |          |
                         DMs/channels  Reactions           Graph API          GitHub     Anthropic
                                       (Chat.ReadWrite)   (Mail, Calendar,   (SSH)      (Sonnet)
                                                          SharePoint, Teams)
```

## Identifiers

| Item | Value |
|---|---|
| VM | `vm-openclaw-agent` (Standard_B2ms, Ubuntu 24.04, Australia East) |
| Public IP | `<VM_PUBLIC_IP>` |
| Domain | `<AGENT_DOMAIN>` |
| Resource Group | `rg-ai-agent-prod` |
| Subscription | `<SUBSCRIPTION_ID>` |
| Tenant ID | `<TENANT_ID>` |
| App (Client) ID | `<APP_CLIENT_ID>` |
| Service Principal ID | `<SERVICE_PRINCIPAL_ID>` |
| Agent UPN | `<AGENT_EMAIL>` |
| Agent Object ID | `<AGENT_OBJECT_ID>` |
| User UPN | `<USER_EMAIL>` |
| User Object ID | `<USER_OBJECT_ID>` |
| Bot Name | `bot-openclaw-agent` |
| Bot Endpoint | `https://<AGENT_DOMAIN>/api/messages` |
| Teams Team ID | `<TEAMS_TEAM_ID>` |
| SharePoint Site | `<SHAREPOINT_DOMAIN>/sites/ai-agent` |
| NSG Name | `vm-openclaw-agentNSG` (not `vm-openclaw-agent-nsg`) |
| Gateway Token | `<GATEWAY_TOKEN>` |
| GitHub Account | `<GITHUB_AGENT_ACCOUNT>` (org: `<GITHUB_ORG>`) |

## SSH Access

```bash
# From the user's machine
ssh -i ~/.ssh/id_rsa azureagent@<VM_PUBLIC_IP>
sudo su - ai-agent   # switch to agent user

# If SSH blocked (IP changed), update NSG:
MY_IP=$(curl -s https://ifconfig.me)
az network nsg rule update \
  --resource-group rg-ai-agent-prod \
  --nsg-name vm-openclaw-agentNSG \
  --name default-allow-ssh \
  --source-address-prefixes "$MY_IP/32"
```

### SSH Port Forwarding (view web UIs locally)

```bash
ssh -i ~/.ssh/id_rsa \
  -L 3000:127.0.0.1:3000 \
  -L 3001:127.0.0.1:3001 \
  -L 3002:127.0.0.1:3002 \
  -L 3003:127.0.0.1:3003 \
  azureagent@<VM_PUBLIC_IP>
```

Then browse:
- `http://localhost:3000` - OpenClaw Control UI (needs gateway token in settings)
- `http://localhost:3001` / `3002` - Any Next.js dev servers Zac is running
- `http://localhost:3003` - OpenClaw browser control

## Key Paths on VM

| Path | Purpose |
|---|---|
| `/home/ai-agent/.openclaw/openclaw.json` | Main config (bot creds, model, channel mapping) |
| `/home/ai-agent/.openclaw/workspace/` | Workspace root (SOUL.md, TOOLS.md, etc.) |
| `/home/ai-agent/.openclaw/workspace/.env` | **Does not exist here** |
| `/home/ai-agent/workspace/.env` | Secrets file (chmod 600) |
| `/home/ai-agent/.openclaw/extensions/msteams/` | Teams plugin (patched monitor.ts + messenger.ts) |
| `/home/ai-agent/.openclaw/agents/main/agent/` | Agent config (auth-profiles.json, models.json) |
| `/home/ai-agent/start-openclaw.sh` | PM2 wrapper (sources .env, sets PATH) |
| `/home/ai-agent/meeting-service/` | Meeting sidecar (stopped but preserved) |
| `/home/ai-agent/start-meeting-service.sh` | PM2 wrapper for meeting service |
| `/etc/caddy/Caddyfile` | Reverse proxy routing |

## Service Management (PM2)

```bash
# As ai-agent user
pm2 list                          # check status
pm2 logs openclaw --lines 50      # recent logs
pm2 logs openclaw --nostream      # snapshot of logs (no follow)
pm2 restart openclaw --update-env # restart with fresh env vars
pm2 stop openclaw                 # stop
pm2 start meeting-service         # start meeting sidecar (currently stopped)

# Caddy (as root/azureagent)
sudo systemctl status caddy
sudo systemctl reload caddy       # after editing Caddyfile
sudo systemctl restart caddy
```

## Deploying Code Changes to the VM

### TypeScript source files (msteams plugin, meeting service)

**CRITICAL**: OpenClaw uses tsx to compile TypeScript plugins. Compiled output is cached in `/tmp/tsx-*`. After editing any `.ts` source file, you MUST clear the cache or changes won't take effect.

```bash
# 1. Edit the file (SCP or direct edit)
# 2. Clear tsx cache
rm -rf /tmp/tsx-*
# 3. Restart OpenClaw
pm2 restart openclaw --update-env
```

### Meeting service (when active)

```bash
# 1. SCP files to /tmp/meeting-src/ on VM
# 2. Copy to service directory and fix ownership
sudo cp /tmp/meeting-src/*.ts /home/ai-agent/meeting-service/src/
sudo chown ai-agent:ai-agent /home/ai-agent/meeting-service/src/*.ts
# 3. Compile and restart
cd /home/ai-agent/meeting-service && npx tsc
pm2 restart meeting-service
```

### Environment variables

```bash
# Edit .env
vim ~/workspace/.env
# Restart to pick up changes
pm2 restart openclaw --update-env
```

### Caddy config

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.bak
sudo vim /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

## Environment Variables (.env)

Located at `/home/ai-agent/workspace/.env` (chmod 600). Sourced by PM2 start scripts.

| Variable | Purpose |
|---|---|
| `ANTHROPIC_API_KEY` | Claude API access |
| `AZURE_TENANT_ID` | Entra ID tenant |
| `AZURE_CLIENT_ID` | App registration client ID |
| `AZURE_CLIENT_SECRET` | App registration secret (6-month expiry) |
| `SHAREPOINT_SITE_ID` | AI Agent Workspace site |
| `BOT_APP_ID` | Same as AZURE_CLIENT_ID (Bot Framework) |
| `BOT_APP_SECRET` | Same as AZURE_CLIENT_SECRET |
| `BOT_TENANT_ID` | Same as AZURE_TENANT_ID |
| `ACS_CONNECTION_STRING` | Azure Communication Services |
| `ACS_ENDPOINT` | ACS endpoint URL |
| `SPEECH_KEY` | Azure Speech service key |
| `SPEECH_REGION` | `australiaeast` |
| `CHROMIUM_PATH` | `/snap/bin/chromium` |
| `AGENT_LOG_WEBHOOK_URL` | Power Automate webhook for #agent-log |
| `OPENAI_API_KEY` | Memory search embeddings (text-embedding-3-small) |
| `BRAVE_API_KEY` | Web search |
| `GH_TOKEN` | GitHub PAT for <GITHUB_AGENT_ACCOUNT> |

**Important**: Values containing `&` must be quoted in .env.

## Graph API Permissions (Current)

All application (Role) permissions on Microsoft Graph, admin-consented:

| Permission | Purpose |
|---|---|
| Mail.Read | Read Zac's mailbox |
| Mail.Send | Send from <AGENT_EMAIL> |
| Calendars.Read | Read Zac's + the user's calendars |
| Calendars.ReadWrite | Write to Zac's calendar |
| Chat.ReadWrite.All | Teams reactions and chat |
| Sites.Read.All | Read SharePoint |
| Sites.ReadWrite.All | Write to SharePoint |
| User.Read.All | Look up user profiles |
| OnlineMeetings.Read.All | Read meeting details |
| OnlineMeetingTranscript.Read.All | Read meeting transcripts |
| ChannelMessage.Read.All | Read Teams channel messages |
| Channel.ReadBasic.All | List channels in teams |
| Team.ReadBasic.All | List teams |
| Calls.JoinGroupCall.All | Join Teams meetings (ACS) |
| Tasks.ReadWrite.All | Microsoft To Do / Planner |
| Teamwork.Migrate.All | Teams data migration |

### Adding a new Graph permission

```bash
# 1. Find the permission ID
az ad sp show --id 00000003-0000-0000-c000-000000000000 \
  --query "appRoles[?value=='Permission.Name'].{id:id,value:value}" -o json

# 2. Get service principal IDs
APP_SP="<SERVICE_PRINCIPAL_ID>"
GRAPH_SP=$(az ad sp show --id 00000003-0000-0000-c000-000000000000 --query id -o tsv)

# 3. Grant the app role
az rest --method POST \
  --url "https://graph.microsoft.com/v1.0/servicePrincipals/$APP_SP/appRoleAssignments" \
  --body "{\"principalId\":\"$APP_SP\",\"resourceId\":\"$GRAPH_SP\",\"appRoleId\":\"<permission-guid>\"}"

# 4. Also add to requiredResourceAccess (for portal visibility)
# Export current perms, add new one, update:
az ad app show --id <APP_CLIENT_ID> --query "requiredResourceAccess" -o json > /tmp/perms.json
# Edit /tmp/perms.json to add the new permission
az ad app update --id <APP_CLIENT_ID> --required-resource-accesses @/tmp/perms.json
```

**Note**: `az ad app permission admin-consent` (bulk consent) often fails. Use the individual appRoleAssignment method above.

## Exchange Application Access Policy

Scopes Mail/Calendar API access to Zac's and the user's mailboxes only.

| Item | Value |
|---|---|
| Security Group | AI Agent Mail Access |
| Group ID | `<MAIL_GROUP_ID>` |
| Members | zac.smith, <USER_USERNAME> |

Created via Exchange Online PowerShell (must run from non-elevated session):
```powershell
Connect-ExchangeOnline
New-ApplicationAccessPolicy -AppId "<APP_CLIENT_ID>" \
  -PolicyScopeGroupId "AI Agent Mail Access" \
  -AccessRight RestrictAccess
```

**Key learning**: Exchange policies require mail-enabled security groups (created via `New-DistributionGroup -Type Security`), not regular Azure AD security groups.

## Teams Integration

### Bot Architecture

- msteams plugin runs a separate Express server on port 3978
- Caddy routes `/api/messages` to port 3978
- Bot Framework POSTs webhook to this endpoint
- Plugin reads credentials from `channels.msteams` in openclaw.json

### Channel IDs

| Channel | Thread ID |
|---|---|
| General | `<CHANNEL_ID_GENERAL>` |
| research | `<CHANNEL_ID_RESEARCH>` |
| internal-ops | `<CHANNEL_ID_INTERNAL_OPS>` |
| project | `<CHANNEL_ID_PROJECT>` |
| agent-log | `<CHANNEL_ID_AGENT_LOG>` |
| ideas | `<CHANNEL_ID_IDEAS>` |
| deployments | `<CHANNEL_ID_DEPLOYMENTS>` |

### Teams App Manifest

Located at `teams-app/zac-smith-bot.zip`. Contains:
- `manifest.json` (schema v1.17, bot-only, scopes: personal/team/groupchat)
- `color.png` (192x192, Zac's avatar)
- `outline.png` (32x32, white silhouette)

Upload via Teams Admin Center > Manage apps > Upload new version.

## Patched Files (must reapply after plugin updates)

### `extensions/msteams/src/monitor.ts`

Three patches applied:

**1. Long-lived promise fix** (prevents crash loop):
The `monitorMSTeamsProvider()` function must return a promise that stays pending while the server runs. Without this, OpenClaw interprets immediate resolution as "provider stopped" and enters restart loop.

**2. Activity ID dedup cache**:
Tracks `req.body.id` and skips duplicates within a 60-second window.

**3. Content-based dedup** (prevents duplicate messages from webhook retries):
Teams retries can assign new activity IDs and timestamps, bypassing ID-based dedup. Content-based key (`sender:text`) catches these retries regardless of ID changes.

### `extensions/msteams/src/messenger.ts`

**Proxy revocation fallback** (~line 477):
When `adapter.process(req, res, handler)` completes and sends the HTTP response, the TurnContext proxy is revoked. If the agent takes longer to generate a response, subsequent context use throws "Cannot perform 'set' on a proxy that has been revoked." The patch catches this and falls back to `adapter.continueConversation()` with a fresh context.

### `extensions/msteams/src/policy.ts`

**DM replyStyle config override**:
`resolveMSTeamsReplyPolicy()` hardcoded `replyStyle: "thread"` for DMs, ignoring the global config. Patched to respect `globalConfig.replyStyle` so DMs also use proactive messaging when configured.

### `openclaw.json` — `replyStyle: "top-level"`

Set on `channels.msteams`. Forces all messages (DMs + channels) to use proactive messaging via `continueConversation()` instead of the original TurnContext. This avoids the proxy revocation issue entirely since proactive contexts aren't tied to the HTTP request lifecycle.

## Troubleshooting

### Zac not responding to messages
1. Check PM2: `pm2 list` (is openclaw "online"?)
2. Check logs: `pm2 logs openclaw --lines 100 --nostream`
3. Check for crash loop: look for `auto-restart attempt` in logs
4. Check Caddy: `sudo systemctl status caddy`
5. Check Bot Framework endpoint: `curl -s https://<AGENT_DOMAIN>/api/messages` (should get 401/405, not timeout)

### Duplicate messages from Zac
- Should be fixed by the three-layer approach: activity ID dedup + content-based dedup + proactive messaging (replyStyle: top-level)
- If duplicates recur, check: `pm2 logs openclaw --lines 100 --nostream | grep -i "skipping duplicate"` to see if dedup is firing
- Check if tsx cache is stale: `rm -rf /tmp/tsx-*` then `pm2 restart openclaw --update-env`
- Verify `replyStyle` is set: `grep replyStyle ~/.openclaw/openclaw.json`
- Check delivery-queue for stuck entries: `ls ~/.openclaw/delivery-queue/`
- Move stuck entries to failed: `mv ~/.openclaw/delivery-queue/*.json ~/.openclaw/delivery-queue/failed/`

### Messages not being delivered (proxy revocation errors)
- With `replyStyle: "top-level"`, proxy revocation should no longer occur
- If it does, check that policy.ts patch is loaded (clear tsx cache)
- Check error log: `pm2 logs openclaw --nostream | grep "proxy.*revoked"`

### STT returns NoMatch (reason=3)
- Normal when there's silence or background noise, not an error
- Check if audio chunks are actually flowing from the browser

### Graph API 403 errors
- Decode the token to check roles: `echo "$TOKEN" | cut -d. -f2 | base64 -d | python3 -m json.tool`
- Add missing permissions using the appRoleAssignment method above
- Token cache refreshes automatically within ~60 seconds of granting

### SSH blocked
- Mobile IP changed. Update NSG rule (see SSH Access section)

### tsx cache preventing code changes from loading
- **This is the #1 gotcha.** Always run `rm -rf /tmp/tsx-*` after editing any .ts plugin file
- Then `pm2 restart openclaw --update-env`

### OpenClaw Control UI shows "offline"
- The WebSocket needs a gateway token
- Open settings in the Control UI and paste: `<GATEWAY_TOKEN>`
- Access via SSH tunnel to `localhost:3000`

### High memory usage
- B2ms has 8GB RAM. OpenClaw + Next.js dev servers can eat 50%+
- Check: `free -h` and `pm2 monit`
- Kill unnecessary dev servers if needed

## OpenClaw Config (openclaw.json)

Key settings:

```json
{
  "agents.defaults.model": "anthropic/claude-sonnet-4-6",
  "agents.defaults.memorySearch.enabled": true,
  "agents.defaults.compaction.mode": "safeguard",
  "gateway.port": 3000,
  "gateway.mode": "local",
  "gateway.auth.mode": "token",
  "tools.web.search.provider": "brave",
  "channels.msteams.dmPolicy": "open",
  "channels.msteams.groupPolicy": "open"
}
```

Modify via:
```bash
openclaw config set <key> <value>
# Or edit directly: vim ~/.openclaw/openclaw.json
# Then: pm2 restart openclaw --update-env
```

## Skills (installed)

Workspace skills (in `~/.openclaw/workspace/skills/`):
- `frontend-design` - Production-grade UI/frontend
- `docx` - Word document manipulation
- `skill-guard` - Security scanner for new skills
- `humanizer` - Tone/writing humanizer

Bundled/npm skills: coding-agent, github, gh-issues, summarize, healthcheck, weather, skill-creator, tmux

## Meeting Service (Currently Stopped)

Chat-only mode (no TTS/voice). Joins Teams meetings via ACS Calling SDK in headless Chromium (Puppeteer). Captures audio via ScriptProcessorNode, transcribes with Azure Speech STT, analyzes with Claude, posts responses to meeting chat.

Key files at `/home/ai-agent/meeting-service/src/`:
- `index.ts` - Express server, join/leave API
- `browser-joiner.ts` - Puppeteer + ACS identity
- `audio-pipeline.ts` - Azure Speech STT
- `transcript.ts` - Claude analysis
- `chat-poster.ts` - ACS Chat + webhook posting

To re-enable: `pm2 start meeting-service`

## Security Notes

- ClawHub is disabled (workspace-only skills)
- NSG: SSH locked to single IP, only HTTPS (443) open publicly
- All secrets in `.env` (chmod 600), pending migration to Azure Key Vault
- Client secret has 6-month expiry (check and rotate)
- Exchange Application Access Policy scopes mail to the agent + the user only
- Control UI accessible at public URL but WebSocket requires auth token

## Pending Items

- [ ] Move secrets to Azure Key Vault
- [ ] Block Control UI from public access via Caddy
- [ ] Phase 10: GitHub SSH keys, template repos, OIDC federation
- [ ] Reapply msteams plugin patches after any plugin update
- [ ] Set `plugins.allow` in openclaw.json to suppress auto-load warning
- [ ] Review client secret expiry and rotate before it expires
