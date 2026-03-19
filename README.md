# OpenClaw Azure Setup

Deploy an enterprise AI agent on Azure with Microsoft 365 integration. The agent runs [OpenClaw](https://openclaw.ai) on a Linux VM, connects to Teams via Bot Framework, and accesses email, calendar, and SharePoint through the Microsoft Graph API.

Built for organisations that need an AI assistant embedded in their existing Microsoft 365 environment -- not a standalone chatbot, but a team member that lives in Teams, has its own mailbox, and operates within your tenant's security boundary.

## Architecture

```
User --> Microsoft Teams --> Azure Bot Service --> Caddy (HTTPS :443)
                                                        |
                                   +--------------------+--------------------+
                                   |                    |                    |
                            /api/messages         /api/meeting/*       everything else
                            msteams plugin        meeting-service      OpenClaw gateway
                            port 3978             port 3979            port 3000
                                   |                                         |
                            Bot Framework                              Agent runtime
                            webhook handler                            (Claude Sonnet)
                                   |                                         |
                            Teams DMs                        Graph API / GitHub / Anthropic
                            & channels                       (Mail, Calendar, SharePoint)
```

**Infrastructure**: Single Azure VM (Standard_B2ms, Ubuntu 24.04) with Caddy for automatic SSL via Let's Encrypt.

**Identity**: The agent is a real Entra ID user with an M365 license, giving it a Teams presence, mailbox, and calendar.

**Authentication**: Single-tenant Entra ID app registration with application-level Graph API permissions. Exchange Application Access Policy scopes mail/calendar access to specific mailboxes only.

**Agent Runtime**: OpenClaw with Claude Sonnet, managed by PM2. ClawHub disabled -- workspace-only skills.

## What's Included

| File | Description |
|---|---|
| `Setup.md.txt` | 10-phase deployment runbook -- the original instructions used to build the environment |
| `DEPLOYMENT-LOG.md` | Every command executed during deployment, with outputs, errors, and learnings |
| `CLAUDE.md` | Project context file for use with Claude Code |
| `.env.template` | Environment variable template with all required secrets listed |
| `teams-app/manifest.json` | Teams app manifest (schema v1.17, bot-only) |
| `meeting-service/infra-skill/SKILL.md` | Operational reference for day-to-day infrastructure management |
| `meeting-service/scripts/setup-azure.sh` | Script to provision ACS and Speech resources for meeting participation |

## Deployment Phases

| Phase | What It Does | Key Resources |
|---|---|---|
| **1** | Azure resource group and VM | B2ms VM, static IP, NSG lockdown |
| **2** | VM base config | Node.js 22, Chromium, PM2, Caddy |
| **3** | Entra ID agent user | M365 license, MFA exclusion |
| **4** | App registration + Graph API | 9 application permissions, admin consent |
| **5** | SharePoint workspace | Private site with Inbox/Outbox/Reference/Projects |
| **6** | Azure Bot registration | F0 tier, Teams channel enabled |
| **7** | DNS and SSL | A record + Caddy auto-HTTPS |
| **8** | OpenClaw install + config | Agent runtime, workspace files, PM2 startup |
| **9** | Teams integration | Private team, channels, app manifest upload |

Phases 1-9 are complete. Phase 10 (GitHub account, SSH keys, OIDC federation) is not yet started.

## Prerequisites

- Azure subscription with Entra ID Global Admin access
- Spare M365 E3 (or equivalent) license
- Anthropic API key
- Azure CLI and M365 CLI installed locally
- A domain with DNS access for creating A records
- Exchange Online PowerShell (for application access policies)

## Quick Start

1. Clone this repo
2. Copy `.env.template` to `.env` and fill in values as you work through each phase
3. Follow `Setup.md.txt` for the step-by-step instructions
4. Refer to `DEPLOYMENT-LOG.md` for exact commands, expected outputs, and troubleshooting

## Graph API Permissions

The app registration requires these application (not delegated) permissions, all admin-consented:

| Permission | Purpose |
|---|---|
| Mail.Read | Read the agent's mailbox |
| Mail.Send | Send email from the agent's address |
| Calendars.Read | Read agent + primary user calendars |
| Chat.ReadWrite.All | Teams reactions and chat access |
| Sites.Read.All | Read SharePoint |
| Sites.ReadWrite.All | Write to SharePoint |
| User.Read.All | Look up user profiles |
| OnlineMeetings.Read.All | Read meeting details |
| ChannelMessage.Read.All | Read Teams channel messages |

An Exchange Application Access Policy restricts mail and calendar access to only the agent's and primary user's mailboxes. Without this, the app registration can access every mailbox in the tenant.

## Security Model

- **Network**: SSH locked to single IP, only HTTPS (443) open publicly. OpenClaw gateway binds to localhost only.
- **Identity**: Single-tenant app registration, no redirect URIs. Agent user excluded from MFA (service account).
- **Data**: Exchange Application Access Policy scopes mail/calendar to specific mailboxes. SharePoint site is private with no external sharing.
- **Agent**: ClawHub disabled. Workspace-only skills. SOUL.md enforces behavioural rules the permissions model can't.
- **Secrets**: Stored in `.env` with chmod 600. Pending migration to Azure Key Vault.
- **Bot**: msteams plugin validates JWT tokens on incoming webhooks. Caddy forwards traffic without terminating auth.

## Common Gotchas

These are documented in detail in `DEPLOYMENT-LOG.md`, but the highlights:

**msteams plugin crash loop** -- The plugin's `monitor.ts` returns immediately instead of a long-lived promise. OpenClaw interprets this as "provider stopped" and restarts in a loop. Fix: patch `monitor.ts` to wrap the return in a Promise that resolves on server close.

**Duplicate messages** -- Two issues stacking: Bot Framework revokes the TurnContext proxy after ~15 seconds (before Claude finishes responding), and Teams webhook retries assign new activity IDs that bypass dedup. Fix: content-based dedup + `replyStyle: "top-level"` for proactive messaging.

**tsx cache** -- OpenClaw caches compiled TypeScript plugins in `/tmp/tsx-*`. After editing any `.ts` file, you must run `rm -rf /tmp/tsx-*` then restart, or your changes won't load.

**Exchange Application Access Policies** -- Require mail-enabled security groups created via `New-DistributionGroup -Type Security` in Exchange Online PowerShell. Regular Azure AD security groups don't work.

**`ChannelMessage.Send`** -- Does not exist as an application permission. Teams message sending goes through Bot Framework, not Graph API.

**Teams manifest** -- Use schema v1.17. The `groupchat` scope must be lowercase. Add `token.botframework.com` to `validDomains`. Upload via Teams Admin Center (sideloading may fail).

## Meeting Service (Optional)

A sidecar service for real-time Teams meeting participation via Azure Communication Services. The agent joins meetings, transcribes audio with Azure Speech STT, analyses the conversation with Claude, and posts responses to the meeting chat.

Status: code written, Azure resources not yet provisioned. See `meeting-service/` for the setup script and operational reference.

## Estimated Costs

| Resource | Monthly Cost (AUD) |
|---|---|
| VM (B2ms) + disk + static IP | ~$104 |
| M365 E3 license | ~$55 |
| Azure Bot (F0) | Free |
| Anthropic API (Claude Sonnet) | Usage-based |
| ACS + Speech (if meeting service enabled) | ~$1/hr STT + $0.004/min calling |

## Pending Work

- [ ] Move secrets to Azure Key Vault
- [ ] Block Control UI from public access via Caddy
- [ ] Phase 10: GitHub SSH keys, template repos, OIDC federation
- [ ] Reapply msteams plugin patches after any plugin update
- [ ] Review client secret expiry and rotate before it expires

## License

This repo contains deployment documentation and configuration templates. No application source code is included. Use at your own risk.
