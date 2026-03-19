# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an infrastructure deployment project for **Accelerate Tech's OpenClaw AI Agent** — an enterprise AI agent running on an Azure Linux VM, integrated with Microsoft 365 (Teams, email, calendar, SharePoint) and GitHub. The primary artifact is `Setup.md.txt`, a 10-phase deployment runbook.

**Company**: Accelerate Tech (<COMPANY_LEGAL_NAME>), Microsoft Solutions Partner — Data & AI, Australian government focus.
**Owner**: the user, primary user of the agent.

## Architecture

```
User ──► Microsoft Teams ──► Azure Bot Service ──► Caddy (HTTPS) ──┬──► msteams plugin (port 3978) → /api/messages
                                                                            ├──► meeting-service (port 3979) → /api/meeting/*, /audio-stream
                                                                            └──► OpenClaw gateway (port 3000) → everything else
                                                                                    │
                                                               ┌────────────────────┼────────────────────┐
                                                               ▼                    ▼                    ▼
                                                        Microsoft Graph      GitHub (SSH)         Anthropic API
                                                     (Mail, Calendar,      (webapp-template,    (anthropic/claude-sonnet-4-6)
                                                      SharePoint, Teams)    bicep-modules)

Teams Meeting ──► ACS Call Automation ──► meeting-service (WebSocket) ──┬──► Azure Speech STT → transcript → Claude → response
                                                                        └──► Azure Speech TTS → audio back to meeting
```

- **VM**: `vm-openclaw-agent` — Standard_B2ms (2 vCPU, 8 GB), Ubuntu 24.04, Australia East
- **Resource Group**: `rg-ai-agent-prod`
- **Process Manager**: PM2 (runs OpenClaw as `ai-agent` Linux user)
- **Reverse Proxy**: Caddy with automatic Let's Encrypt SSL at `<AGENT_DOMAIN>`
- **Identity**: "Zac Smith [Agent]" — `<AGENT_EMAIL>` (Entra ID user with M365 E3 license, MFA-excluded)
- **App Registration**: "OpenClaw Agent API" — single-tenant daemon with Graph application permissions
- **Mail Access**: Agent reads and sends from its own mailbox (`<AGENT_EMAIL>`); reads the user's calendar
- **Teams Bot**: msteams plugin on port 3978 (patched `monitor.ts` — see DEPLOYMENT-LOG.md)
- **Meeting Service**: Sidecar on port 3979 (ACS Call Automation + Azure Speech STT/TTS)
- **OpenClaw Version**: 2026.2.26, msteams plugin 2026.2.25

## Deployment Status

| Phase | Description | Status |
|---|---|---|
| 1 | Azure Resource Group & VM | Done |
| 2 | VM base config (Node.js 22, Chromium, PM2, Caddy) | Done |
| 3 | Entra ID agent user account | Done |
| 4 | Entra ID app registration + Graph API permissions | Done |
| 5 | SharePoint workspace (Inbox/Outbox/Reference/Projects) | Done |
| 6 | Azure Bot registration with Teams channel | Done |
| 7 | DNS & SSL via Caddy | Done |
| 8 | OpenClaw installation + workspace files | Done |
| 9 | Teams private team + project channels | Done |
| — | Security audit | Done |
| — | Workspace file overhaul (SOUL, IDENTITY, USER, TOOLS, HEARTBEAT) | Done |
| — | Teams bot integration (manifest, routing, crash fix, DM policy) | Done |
| — | Graph permissions expansion (Mail.Send, Chat.ReadWrite.All, profile pic) | Done |
| 10 | GitHub account, SSH keys, template repos, OIDC federation | Not started |
| — | Exchange Application Access Policy + mailbox delegation | Done |
| — | Real-time Teams meeting participation (ACS + Speech) | In progress |
| — | Move secrets to Azure Key Vault | Not started |

## Key Security Constraints

- ClawHub is **disabled** — workspace-only skills, no remote skill sources
- Calendar is **read-only** (Calendars.Read) — agent reads own + the user's calendar
- Email: read own mailbox + send from `<AGENT_EMAIL>` (Mail.Read, Mail.Send) — external sends require the user's approval
- Exchange Application Access Policy scopes mail/calendar to the agent + user only (pending creation)
- NSG locks SSH (22) to a single IP; only HTTPS (443) open publicly
- All deployments go through **PR review** — never push directly to main
- Client data must stay siloed per Teams channel

## Agent Tech Stack Preferences

When the agent builds web apps, it uses:
- Next.js 14 + TypeScript, Tailwind CSS, shadcn/ui
- Azure Bicep for IaC, GitHub Actions for CI/CD
- Azure App Service (Linux) for hosting

## Key Files on VM

| Path | Purpose |
|---|---|
| `/home/ai-agent/.openclaw/openclaw.json` | Main OpenClaw config (bot creds, model, policies) |
| `/home/ai-agent/.openclaw/workspace/SOUL.md` | Agent identity and behaviour rules |
| `/home/ai-agent/.openclaw/workspace/IDENTITY.md` | Name, email, vibe |
| `/home/ai-agent/.openclaw/workspace/USER.md` | the user's profile |
| `/home/ai-agent/.openclaw/workspace/TOOLS.md` | Graph API, SharePoint, Teams, brand config |
| `/home/ai-agent/.openclaw/workspace/HEARTBEAT.md` | Periodic check schedule |
| `/home/ai-agent/.openclaw/extensions/msteams/src/monitor.ts` | Patched — see DEPLOYMENT-LOG.md |
| `/home/ai-agent/start-openclaw.sh` | PM2 wrapper script (sources .env) |
| `/home/ai-agent/meeting-service/` | Meeting sidecar service (ACS + Speech) |
| `/home/ai-agent/start-meeting-service.sh` | PM2 wrapper for meeting service |
| `/home/ai-agent/workspace/.env` | Secrets (chmod 600) |
| `/etc/caddy/Caddyfile` | Reverse proxy routing |

## Environment Variables (on the VM)

```
ANTHROPIC_API_KEY, AZURE_TENANT_ID, AZURE_CLIENT_ID, AZURE_CLIENT_SECRET, SHAREPOINT_SITE_ID,
ACS_CONNECTION_STRING, ACS_ENDPOINT, SPEECH_KEY, SPEECH_REGION
```

Secrets are stored in `.env` during setup, then migrated to Azure Key Vault.

## SSH Access

```bash
ssh -i ~/.ssh/id_rsa azureagent@<VM_PUBLIC_IP>
sudo su - ai-agent  # to access OpenClaw
```

Note: Windows PATH leaks into SSH sessions from Git Bash — use wrapper scripts or explicit PATH when running commands via `sudo su - ai-agent`.

## Working with This Repo

Key documents and code:
- `Setup.md.txt` — Original 10-phase deployment runbook
- `DEPLOYMENT-LOG.md` — Executed steps with exact commands and learnings
- `teams-app/` — Teams app manifest and icons (`zac-smith-bot.zip`)
- `meeting-service/` — Meeting sidecar service (TypeScript/Node.js) for real-time Teams meeting participation via ACS