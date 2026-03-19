# YouTube Script: Deploying an Enterprise AI Agent on Azure with Teams Integration

**Target length**: 25-30 minutes
**Tone**: Conversational, first-person, practitioner sharing real experience

---

## 0:00 - Hook

`[SCREEN: Teams chat showing a conversation with the AI agent]`

So I built an AI agent that lives in Microsoft Teams, reads my email and calendar, accesses SharePoint documents, and runs on Claude Sonnet as its brain. It took me a weekend to deploy -- and about three days to debug the weird edge cases that nobody warns you about.

In this video I'm going to walk you through the full setup, step by step. Everything from the Azure VM to the Entra ID identity, Graph API permissions, Bot Framework integration, and all the things that broke along the way.

All the commands and config files are in a GitHub repo I'll link in the description. Let's get into it.

`[CUT TO: Architecture diagram]`

---

## 1:00 - Architecture Overview

`[SCREEN: Architecture diagram from the blog post / whiteboard]`

Here's what we're building. At the center is a single Azure VM running Ubuntu. On that VM we have three services:

First, the OpenClaw gateway on port 3000. This is the agent runtime -- it's where Claude Sonnet lives and does the actual thinking.

Second, the msteams plugin on port 3978. This is a separate Express server that handles the Bot Framework webhook. When someone sends a message in Teams, Microsoft's Bot Service POSTs it to this endpoint.

Third, and this is optional, a meeting service on port 3979 for real-time Teams meeting participation. We won't deploy that today but I'll talk about it at the end.

Sitting in front of all of this is Caddy, which is a reverse proxy that handles SSL termination automatically via Let's Encrypt. It routes traffic to the right service based on the URL path.

`[SCREEN: Point to each component as you describe it]`

The agent authenticates to Microsoft 365 through an Entra ID app registration with application-level Graph API permissions. It can read email, read calendars, access SharePoint, and interact in Teams channels.

One thing to note -- the agent runs as a real user in your M365 tenant. It has its own identity, its own mailbox, its own Teams presence. It's not a faceless service account. That's a deliberate design choice for how it shows up in conversations.

---

## 3:00 - Phase 1-2: Azure VM Setup

`[SCREEN: Azure Portal or terminal with az CLI]`

Let's start with the infrastructure. We need a resource group and a VM.

I went with a Standard B2ms -- that's 2 vCPUs, 8 gigs of RAM. For a single-agent setup running Claude Sonnet, that's plenty. It runs about 100 bucks a month Australian.

`[SCREEN: Show the az vm create command from the repo]`

The VM is Ubuntu 24.04 with a 64 gig premium SSD and a static public IP. That static IP is important because we'll be pointing a domain at it.

First security step -- lock down the network security group immediately after creation. SSH is restricted to your current public IP only. HTTPS 443 is the only other inbound rule. Everything else is denied by default.

`[SCREEN: NSG rules in portal or CLI output]`

On the VM itself, we install four things: Node.js 22, headless Chromium for browser-based agent skills, PM2 as the process manager, and Caddy as the reverse proxy.

We also create a dedicated Linux user called `ai-agent`. OpenClaw runs under this user, keeping it isolated from the admin account.

`[CUT TO: Terminal showing the install commands running]`

---

## 7:00 - Phase 3-4: Identity and Permissions

`[SCREEN: Entra ID portal or CLI]`

This is where it gets interesting. The agent needs to be a real person in your M365 tenant. Well, a real-ish person.

We create an Entra ID user account with a display name, assign it an M365 E3 license -- it needs that for a Teams presence and a mailbox -- and set the usage location.

`[SCREEN: az ad user create command]`

You also need to exclude this account from MFA. Add it to your Conditional Access policy's exclusion list. Without this, the agent can't authenticate programmatically. Yes, this is a security trade-off. You're accepting it because the account is controlled by automation, not a human who might get phished.

`[SCREEN: Conditional Access policy in portal]`

Now, the app registration. This is separate from the user account. The app registration is how the agent authenticates to the Graph API.

Create a single-tenant registration with no redirect URIs -- it's a daemon service. Generate a client secret and store it securely. You won't see it again after creation.

`[SCREEN: App registration blade showing API permissions]`

Then we add the Graph API permissions. And this is important -- these are application permissions, not delegated. The agent runs as a background service, not on behalf of a signed-in user.

The core set is: Mail.Read, Mail.Send, Calendars.Read, Sites.ReadWrite.All, Chat.ReadWrite.All, User.Read.All, and ChannelMessage.Read.All.

One gotcha that cost me time: `ChannelMessage.Send` does not exist as an application permission. Sending messages in Teams goes through Bot Framework, not Graph API.

Grant admin consent for each permission. And here's a pro tip -- the bulk consent command in the Azure CLI often fails silently. Grant them individually through the appRoleAssignments endpoint. It's more verbose but it actually works. The exact commands are in the repo.

`[CUT TO: Terminal showing permission grant commands]`

---

## 12:00 - Phase 5-6: SharePoint and Bot Registration

`[SCREEN: SharePoint site]`

Quick section. Create a private SharePoint site for the agent's document workspace. I set up four libraries: Inbox for dropping files in, Outbox for completed work, Reference for templates and guidelines, and Projects for working documents organized by client.

Disable external sharing and limit membership to you and the agent. This is a closed workspace.

`[SCREEN: Azure Bot Service blade]`

For the bot registration, create an Azure Bot resource on the free tier. Enable the Microsoft Teams channel. The messaging endpoint is your domain slash api slash messages -- but we can't test this until DNS is configured.

The bot uses the same app registration from Phase 4. Set the app type to SingleTenant and provide your tenant ID.

`[CUT TO: Bot configuration in portal]`

---

## 15:00 - Phase 7-8: DNS, SSL, and OpenClaw

`[SCREEN: DNS provider / Caddy config]`

Point a subdomain at your VM's static IP with an A record. Once DNS propagates, set up the Caddyfile.

And here's something that tripped me up. The Caddy config needs to route two different paths to two different ports.

`[SCREEN: Caddyfile contents]`

The msteams plugin runs its own Express server on port 3978. It is not part of the main OpenClaw gateway on port 3000. Bot Framework webhooks go to 3978, everything else goes to 3000. If you send the webhook traffic to 3000, the agent will never receive messages and you'll spend hours wondering why.

Caddy handles the SSL certificate automatically. First request triggers Let's Encrypt provisioning. No certbot, no cron jobs.

`[SCREEN: Terminal - SSH into VM as ai-agent user]`

Now install OpenClaw on the VM. Switch to the ai-agent user, run the install script, configure it with your Anthropic API key and the model name.

Important detail: the model name needs a provider prefix. It's `anthropic/claude-sonnet-4-6`, not just `claude-sonnet-4-6`.

`[SCREEN: .env file structure (with placeholders)]`

Store all your secrets in a single .env file with chmod 600 permissions. Create a PM2 wrapper script that sources this file and starts the gateway.

For the workspace files -- SOUL.md defines the agent's identity and behaviour rules. IDENTITY.md is its name and personality. TOOLS.md configures its environment. These all get injected into every system prompt, so keep them concise.

The critical security decision: disable ClawHub entirely. Set skills to workspace-only mode. This means the agent cannot install anything from external sources. You control what it can do.

`[SCREEN: openclaw.json config snippet]`

Start it up with PM2, save the process list, and configure auto-start on boot. Verify it's running by hitting the domain in a browser -- you should see the OpenClaw Control UI.

---

## 19:00 - Phase 9: Teams Integration and Testing

`[SCREEN: Teams Admin Center]`

Create a private Team with your channels. Add the agent as a member.

Now build the Teams app manifest. This is just a JSON file plus two icon PNGs, zipped together. The schema version matters -- use v1.17. I originally tried v1.19 and hit parsing errors.

`[SCREEN: manifest.json contents]`

A few things I had to fix in the manifest:
- `groupChat` scope must be lowercase: `groupchat`
- Don't include empty `commandLists` arrays
- Add `token.botframework.com` to `validDomains`
- Set accent color to `#FFFFFF` to avoid validation errors

Upload via the Teams Admin Center, not by sideloading in the Teams client. Sideloading failed for me with a generic "Something went wrong" error. The admin center upload works, but heads up -- it can take up to 24 hours to propagate to users.

`[SCREEN: Teams showing the agent responding to a message]`

Test it by sending a DM to the agent. If everything is wired up correctly, you'll see the message flow through Bot Framework to your VM, hit the msteams plugin, get processed by OpenClaw, and come back as a response in Teams.

---

## 22:00 - Security Hardening

`[SCREEN: Bullet list or diagram of security layers]`

Let's talk about what we've done to lock this down.

Network level: SSH is restricted to a single IP. Only HTTPS is publicly accessible. The OpenClaw gateway binds to localhost only -- it's not directly reachable from the internet.

Identity level: single-tenant app registration, no redirect URIs. The agent user is MFA-excluded but the account is fully automated.

Data level: Exchange Application Access Policy. This is the one people miss. Without it, your app registration can read everyone's email in the tenant. The access policy scopes mail and calendar access to only the agent's and the primary user's mailboxes.

And this requires a mail-enabled security group, which you have to create through Exchange Online PowerShell. Regular Azure AD security groups don't work -- Exchange can't resolve them. Use `New-DistributionGroup -Type Security`. Also, `Connect-ExchangeOnline` fails in elevated PowerShell sessions, so run it from a normal window.

`[SCREEN: Exchange PowerShell commands]`

Application level: ClawHub is disabled. SOUL.md enforces behavioral rules that the permissions model can't -- like not reading certain mailboxes even though the Exchange policy technically allows it.

What's still pending: moving secrets to Azure Key Vault, and blocking the Control UI from public access via Caddy routing.

---

## 25:00 - Things That Broke

`[SCREEN: Error logs / code snippets]`

Here are the three biggest issues I hit, because I guarantee you'll hit them too if you try this.

**Number one: the crash loop.** The msteams plugin started and immediately entered an auto-restart cycle. The root cause was a bug in the plugin's monitor code. It returned a result immediately instead of returning a long-lived promise. OpenClaw's lifecycle expects the provider to stay alive. When the promise resolved instantly, the gateway thought the provider had stopped and restarted it. Each restart hit a port-already-in-use error because the previous server was still running.

Fix: wrap the return in a Promise that only resolves when the HTTP server actually closes.

**Number two: duplicate messages.** The agent was sending every response twice. Two things stacking. First, when Claude takes longer than about 15 seconds, Bot Framework revokes the TurnContext proxy. The fallback handler then re-sends everything using a fresh context. Second, Teams webhook retries assign new activity IDs, so the dedup logic didn't catch them.

Fix: three patches. Content-based dedup keyed on sender and message text. A config override so DMs respect the global reply style. And setting reply style to "top-level" which forces proactive messaging and sidesteps the proxy issue entirely.

**Number three: the tsx cache.** OpenClaw compiles TypeScript plugins with tsx, and the output is cached in /tmp. After editing any TypeScript file, you have to clear the cache manually or your changes won't load. This one burned me multiple times.

`[SCREEN: The tsx cache clear command]`

```bash
rm -rf /tmp/tsx-*
pm2 restart openclaw --update-env
```

Tattoo that on your forearm if you have to.

---

## 28:00 - What's Next and Wrap Up

`[SCREEN: Roadmap / future phases]`

So where does this go from here?

**Azure Key Vault** for secret management. Right now everything is in a flat .env file. That works for a POC but it's not production-grade.

**GitHub integration** -- the agent gets its own GitHub account with SSH keys and template repos. It can scaffold and deploy web apps via Bicep and GitHub Actions with OIDC federation. No stored credentials.

**Meeting service** -- this is the ambitious one. A sidecar service that joins Teams meetings via Azure Communication Services, transcribes audio with Azure Speech in real-time, analyzes the conversation with Claude, and posts responses to the meeting chat. The code is written, the Azure resources just need provisioning.

`[SCREEN: Repo link / description]`

Everything from this video is in the GitHub repo linked in the description. The full deployment log with every command I ran, the setup guide, the infra skill for ongoing operations, and the Teams app manifest.

If you found this useful, drop a like and let me know in the comments if you end up deploying your own. I'm curious how other people's setups compare.

Thanks for watching.

`[END CARD: Repo link, subscribe button, related videos]`
