# How I Deployed an Enterprise AI Agent on Azure with Teams, Email, and SharePoint Integration

I recently built and deployed an enterprise AI agent for our consultancy using [OpenClaw](https://openclaw.ai) -- an open-source agent runtime that sits on a Linux VM and connects to Microsoft 365 via Graph API and Bot Framework. The agent lives in Teams, reads email and calendar, accesses SharePoint, and runs on Claude Sonnet as its brain.

This post walks through the full deployment, what went wrong, and what I'd do differently. All commands and config files are in the [companion repo](https://github.com/jdiekman/openclaw-azure-setup).

## What we're building

The architecture looks like this:

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

A single Azure VM (Standard_B2ms, 2 vCPU / 8 GB) runs everything. Caddy handles SSL termination and routes traffic to either the Teams webhook handler or the main OpenClaw gateway. The agent authenticates to Microsoft 365 through an Entra ID app registration with application-level Graph API permissions.

## Prerequisites

Before starting, you'll need:

- An Azure subscription with Entra ID Global Admin access
- A spare M365 E3 (or equivalent) license for the agent's identity
- An Anthropic API key
- Azure CLI and M365 CLI installed locally
- A domain you can point at the VM's IP address
- DNS provider access for creating A records

## Phase 1-2: Azure VM and base configuration

Start by creating a resource group and spinning up an Ubuntu 24.04 VM. I went with a B2ms in Australia East -- roughly $104 AUD/month including the static IP and premium SSD.

The key security step here is locking down the NSG immediately. SSH (port 22) gets restricted to your current public IP only, and HTTPS (port 443) is the only other inbound rule. Everything else is denied.

On the VM itself, install Node.js 22 LTS, headless Chromium (for browser-based skills), PM2 for process management, and Caddy as the reverse proxy. Caddy is the right choice here because it handles Let's Encrypt certificates automatically -- no certbot cron jobs or manual renewals.

Create a dedicated `ai-agent` Linux user. OpenClaw runs under this user, keeping it isolated from the admin account you SSH in with.

## Phase 3: Giving the agent an identity

The agent needs to exist as a real user in your M365 tenant. Create an Entra ID user account with a display name, assign it an M365 license (needed for Teams and a mailbox), and set its usage location.

You also need to exclude this service account from MFA. Add it to the exclusion list on your existing Conditional Access policy. Without this, the agent can't authenticate programmatically.

One thing I learned the hard way: the UPN (user principal name) you choose matters. I changed mine three times before settling on the final format. Pick something sensible upfront.

## Phase 4: App registration and Graph API permissions

Create a single-tenant app registration with no redirect URIs (it's a daemon/service). Generate a client secret with a 6-month expiry and store it somewhere safe immediately -- you won't see it again.

Then add application-level Graph API permissions. The initial set I used:

- **Mail.Read** and **Mail.Send** -- read the agent's mailbox, send from its address
- **Calendars.Read** -- read the agent's calendar and the primary user's calendar
- **Sites.Read.All** and **Sites.ReadWrite.All** -- SharePoint document access
- **Chat.ReadWrite.All** -- Teams reactions and richer chat interactions
- **User.Read.All** -- look up user profiles
- **OnlineMeetings.Read.All** -- meeting details
- **ChannelMessage.Read.All** -- read Teams channel messages

Grant admin consent for each permission. The `az ad app permission admin-consent` command often fails silently. I found that granting permissions individually via the `appRoleAssignments` endpoint is more reliable. The companion repo has the exact commands.

One gotcha: `ChannelMessage.Send` doesn't exist as an application permission. Teams message sending goes through Bot Framework instead.

## Phase 5: SharePoint workspace

Create a private SharePoint site to serve as the agent's document workspace. I set up four document libraries: Inbox (drop files for the agent to process), Outbox (agent places completed work), Reference (persistent templates and guidelines), and Projects (working documents by client).

Lock it down by disabling external sharing and limiting membership to yourself and the agent account.

## Phase 6: Azure Bot registration

Register an Azure Bot resource (F0 free tier is fine for a POC) and enable the Microsoft Teams channel. The bot's messaging endpoint will be `https://your-domain/api/messages` -- but you can't test this until DNS and Caddy are configured.

The bot uses the same app registration from Phase 4. Set `msaAppType` to `SingleTenant` and provide your tenant ID.

## Phase 7: DNS and SSL

Point a subdomain at your VM's static public IP with an A record. Once DNS propagates, configure Caddy:

```
yourdomain.com {
    handle /api/messages {
        reverse_proxy localhost:3978
    }
    handle {
        reverse_proxy localhost:3000
    }
}
```

This is a critical detail I missed initially: the msteams plugin runs a **separate** Express server on port 3978. It's not part of the main OpenClaw gateway on port 3000. Bot Framework webhook POSTs to `/api/messages` must reach port 3978, while everything else goes to the gateway.

Caddy provisions the SSL certificate automatically via Let's Encrypt on first request. No manual steps needed.

## Phase 8: OpenClaw installation

Switch to the `ai-agent` user and install OpenClaw. Run the onboard wizard, configure the model (`anthropic/claude-sonnet-4-6` -- the provider prefix matters), and install the msteams plugin.

Store all environment variables in a `.env` file at `/home/ai-agent/workspace/.env` with `chmod 600`. Create a PM2 wrapper script that sources this file and starts the gateway.

The workspace files (SOUL.md, IDENTITY.md, USER.md, TOOLS.md, HEARTBEAT.md) all get injected into every system prompt turn, so keep them concise. These define the agent's identity, behaviour rules, tool configuration, and periodic check schedule.

Important security decision: disable ClawHub entirely. Workspace-only skills means the agent can't install anything from external sources without you manually adding it.

## Phase 9: Teams integration

Create a private Team, add the agent as a member, and set up project channels. Build a Teams app manifest (schema v1.17 -- not newer, or you'll hit parsing errors) with the bot ID and upload it via the Teams Admin Center.

Sideloading through the Teams client failed for me. The Admin Center upload works reliably, but propagation to users can take up to 24 hours.

## Things that broke (and how I fixed them)

### The crash loop

The msteams plugin entered an auto-restart cycle immediately after starting. The root cause was a bug in `monitor.ts` -- the function returned a result immediately after calling `listen()` instead of returning a long-lived promise. OpenClaw's lifecycle expects the provider to stay alive, so when the promise resolved instantly, it interpreted that as "provider stopped" and restarted it. Each restart hit `EADDRINUSE` because the previous server was still bound to the port.

The fix: wrap the return in a `new Promise()` that only resolves when the HTTP server actually closes.

### Duplicate messages

The agent was sending every response twice. Two issues stacking on each other:

1. **Proxy revocation**: When Claude takes longer than ~15 seconds to respond, Bot Framework sends the HTTP response and revokes the TurnContext proxy. The messenger's fallback to `continueConversation()` then re-sends everything.

2. **Webhook retry bypass**: The activity ID dedup only keyed on `req.body.id`. Teams retries assign new IDs, bypassing it entirely.

The fix was three patches: content-based dedup in `monitor.ts` (keyed on `sender:text`), a config override in `policy.ts` so DMs respect the global `replyStyle`, and setting `replyStyle: "top-level"` in `openclaw.json` to force proactive messaging everywhere. Proactive messaging creates a fresh context not tied to the HTTP request lifecycle, sidestepping the proxy revocation entirely.

### The tsx cache

OpenClaw uses tsx to compile TypeScript plugins. The compiled output is cached in `/tmp/tsx-*`. After editing any `.ts` source file, you **must** clear this cache or your changes won't take effect. This cost me an embarrassing amount of debugging time.

```bash
rm -rf /tmp/tsx-*
pm2 restart openclaw --update-env
```

### Exchange application access policies

These require mail-enabled security groups, not regular Azure AD security groups. You have to use `New-DistributionGroup -Type Security` in Exchange Online PowerShell. Graph API and `az ad group create` won't work. Also, `Connect-ExchangeOnline` fails in elevated PowerShell sessions due to the WAM broker -- run it from a normal window.

## Security hardening

Beyond the basics (NSG lockdown, SSH key-only, secrets in chmod 600 files), there are a few things worth calling out:

- **Exchange Application Access Policy** scopes mail and calendar API access to only the agent's and primary user's mailboxes. Without this, the app registration could read everyone's email in the tenant.
- **ClawHub disabled** -- no external skill sources, workspace-only mode.
- **SOUL.md behavioural rules** enforce restrictions that the permissions model can't (like not reading the user's email even though the Exchange policy technically allows it).
- **Bot Framework webhook** is JWT-authenticated by the msteams plugin. Caddy just forwards the traffic.

Pending: secrets should move to Azure Key Vault, and the Control UI should be blocked from public access via Caddy routing rules.

## What's next

- **Azure Key Vault** for secret management instead of flat .env files
- **GitHub integration** (Phase 10) -- SSH keys, template repos, OIDC federation for GitHub Actions deployments
- **Meeting service** -- a sidecar that joins Teams meetings via ACS Call Automation, transcribes audio with Azure Speech, and responds via Claude
- **Automated secret rotation** for the client secret (6-month expiry)

## Resources

- [Companion repo](https://github.com/jdiekman/openclaw-azure-setup) with all commands, config files, and the full deployment log
- [OpenClaw documentation](https://openclaw.ai)
- [Azure Bot Service documentation](https://learn.microsoft.com/en-us/azure/bot-service/)
- [Microsoft Graph API permissions reference](https://learn.microsoft.com/en-us/graph/permissions-reference)
