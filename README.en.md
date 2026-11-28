<div align="center">

<img src="docs/images/icon.png" alt="Claude Network Guard" width="128" />

# Claude Network Guard

**Keep Claude on your Mac on the one network you approved.**
If that network drops or its IP changes, Claude goes offline at once. It never quietly switches to another network.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black) ![Apple Silicon](https://img.shields.io/badge/Apple_Silicon-M1_or_later-555) ![Version](https://img.shields.io/badge/version-0.9.0-4F46E5)

[简体中文](README.md) · **English**

[What it does](#what-it-does) · [Remember these first](#remember-these-first) · [Install](#install-once) · [Everyday use](#everyday-use) · [FAQ](#faq)

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/running-dark.png">
  <img src="docs/images/running.png" alt="Home screen while protecting" width="820" />
</picture>

<sub>Screenshots use sample data</sub>

</div>

> Unofficial software, not affiliated with Anthropic. The Claude name and character belong to Anthropic.

---

## What it does

An example: you are at an airport, your Mac is on the airport Wi‑Fi and also plugged into your iPhone. You want Claude to use only the phone.

The problem: if the cable comes loose, or your VPN or proxy app restarts, macOS **switches to another network on its own**, and Claude goes with it without telling you.

Guard handles this:

1. You pick a network, **look at its IP yourself**, and click "Approve" if you are happy with it.
2. Guard opens Claude on that network and **locks Claude to it**.
3. If the network drops or the IP changes, **Claude goes offline immediately** (the app stays open, your chats stay), and waits for you.
4. Other apps (browsers, chat apps…) are unaffected.

When you are not protecting, it does nothing.

It does **not** provide a VPN, proxy or account, and it does not change device fingerprints, time zone or language.

## Remember these first

> **1. Always open Claude from Guard.** Claude opened from the Dock or Spotlight is not protected (Guard closes it during protection).
>
> **2. Guard only covers Claude Desktop on this Mac.** The Claude phone app and claude.ai in a browser are **not** covered; they use whatever network they are on. To use only your approved IP, don't use Claude on your phone or the web during protection.
>
> **3. With an iPhone cable or hotspot, Claude uses your phone's cellular IP.** A VPN app on the phone (such as Shadowrocket) usually does **not** change that. Check what the test site shows before approving.
>
> **4. Red is not a crisis.** It means Claude was safely cut off. Reconnect and click "Check and restore".
>
> **5. When done, click "Stop and quit Claude".**
>
> **Tip:** turn off "open at login" for Claude (in Claude's settings or System Settings › General › Login Items), so it can't go online before you start protection.

---

## Requirements

- Apple silicon Mac (M1 or later), macOS 13 or later. **Only tested on macOS 27 so far**
- Official Claude Desktop in Applications
- One of: **iPhone + cable**, **system-wide VPN**, **iPhone hotspot**
- Your Mac login password

No Xcode or Apple developer account needed.

## Install (once)

**1. Quit Claude completely:** press ⌘Q in Claude. Closing the window is not enough.

**2. Open Terminal** (⌘ Space, search "Terminal"), paste this line and press Return:

```bash
git clone https://github.com/z3Ra1n/claude-network-guard.git ~/ClaudeNetworkGuard
```

> If macOS offers to install the command line developer tools, click "Install", then paste the line again.

**3. Paste this line and press Return:**

```bash
cd ~/ClaudeNetworkGuard && ./install.sh
```

> It builds on your Mac, which takes a few minutes.
> When asked for a password, type your Mac login password and press Return. **Nothing appears while you type; that is normal.**

**4. Guard opens when done.** Later, find **Claude Network Guard** in Applications.

> Please install this way rather than downloading a zip from the web page; macOS may block it.

**Two things to allow afterwards:**

| What pops up / where | What to do |
|---|---|
| "Background item added" (or System Settings › General › Login Items & Extensions) | Keep Guard **on**. Cutting off and blocking depend on it |
| Guard › Settings › Alerts | Enable, then click "Allow". You get a notice when Claude is cut off (recommended) |

For the phone: tap "**Trust** this computer" after plugging in, and turn on Settings › Personal Hotspot › "**Allow Others to Join**".

<details>
<summary>Permissions Guard does not need</summary>

Full Disk Access, Accessibility, Screen Recording, Contacts, Location and system extensions are **not** needed. If something asks for them in Guard's name, say no.

</details>

---

## Everyday use

**Just keep clicking the button on the home card.** It walks you through.

1. **Pick a network, click "Check line".** This does not contact Claude.
2. **Click "Open test site",** look at the IP (country, type, reputation), then click "Done".
3. **If you're happy, click "Approve and start".** Guard checks the IP once more and opens Claude only if it matches.
4. **When done, click "Stop and quit Claude".**

An approval lasts 24 hours and is void as soon as the IP changes.

| Card colour | Meaning |
|---|---|
| 🔵 Blue | Not protecting |
| 🟢 Green | Protecting, all good |
| 🟡 Yellow | Protecting, something to look at (tap for details) |
| 🔴 Red | Cut off, waiting for you |

<div align="center"><img src="docs/images/prepare.png" alt="Checks and hints before starting" width="640" /></div>

### Which network to choose

| Choice | Good for | Claude's IP | Other apps |
|---|---|---|---|
| **iPhone cable** (recommended) | Untrusted airport, hotel or café Wi‑Fi | Phone's cellular IP | Keep using Wi‑Fi or VPN |
| **System-wide VPN** | Home or office with a full-tunnel VPN | VPN's IP | Also use the VPN |
| **iPhone hotspot** | No cable with you | Phone's cellular IP | Whole Mac uses the phone |

"Check only" shows the current network without protecting.

---

## FAQ

**My Mac uses a VPN for Google while Claude is protected over the iPhone cable. Do they interfere?**
No (tested). The browser keeps using the VPN; Claude uses only the phone.

**If my VPN or proxy app restarts, crashes or falls back to "direct", can my real IP leak to Claude?**
By our rules and tests, no:
- When the VPN drops, Claude is cut off in under a second (tested).
- If the proxy app sends traffic "direct" over Wi‑Fi, or any other app tries to bypass the VPN to reach Claude, it is blocked and the home screen says "Blocked xxx" (tested).
- One case is not covered: the network stays up but the exit IP silently changes (e.g. the proxy switches nodes). Guard checks every 5 seconds, so it may be a few to a dozen seconds late. **With a VPN, pin Claude to one fixed node, not an auto-select / fallback / load-balance group.**

**Can I use it at an airport right away?**
Yes. Plug in the phone (or join its hotspot) and follow the four steps. Remember point 2: the Claude phone app is not covered.

**Are Claude cloud projects (cloud Cowork, cloud sessions) protected?**
The cloud part runs on Anthropic's servers with their IPs, unrelated to your network. Viewing and controlling them **in the Claude opened by Guard** is protected; checking on them from the phone app or the web is not.

**It turned red / cut off?**
Claude is still open and your chats are there. Reconnect and click "Check and restore". It never restores by itself.

**The IP changed?**
Back to the original IP: restore directly. A new IP: check, view the site and approve again.

**I need to sign in to Claude again?**
Sign-in opens an external browser, which is blocked during protection. Stop protection first. With the cable, turn Wi‑Fi off while signing in so the whole Mac uses the phone; then turn Wi‑Fi back on and start again from Guard.

**It says it blocked some app?**
An app outside protection tried to reach Claude over another network and was stopped. Usually a browser's Claude extension or a claude.ai tab; close or remove it.

**Claude was closed after an automatic update?**
After updating it relaunches itself outside protection, so Guard closes it. Start it again from Guard.

**iPhone not detected?**
Unlock the phone, tap "Trust", turn on Personal Hotspot; replug the cable if needed.

**"Both lines have the same exit"?**
Your Mac's Wi‑Fi is this phone's hotspot. Use another Wi‑Fi, or choose "iPhone hotspot".

**Need a company or school server?**
Claude can't reach private networks during protection by default. Add `IP:port` under Settings › Allowed private addresses to allow just that one.

**Guard crashed?**
Protection continues. Cutting off and blocking are done by the background component and the system firewall.

---

## What it covers

| | |
|---|---|
| ✅ Covered | Claude Desktop opened from Guard: chat, Code, built-in browser, terminal panel, and the commands they run |
| ❌ Not covered | Claude on your phone, claude.ai in a browser, browser Claude extensions |
| ❌ Not covered | Claude opened directly from the Dock |
| ❌ Not covered | `claude` you run yourself in Terminal or VS Code ([one exception](BOUNDARIES.md)) |
| ❌ Not covered | Other apps Claude opens for you, e.g. Safari, Xcode, Simulator; they use their own network |

### What it can't prevent

- **The few to dozen seconds when the network stays up but the IP silently changes.**
- **IPs written in content.** If a screenshot, page or file shows your IP, Claude can read it. That's why Guard hides IPs by default; also don't let Claude open IP-check pages or account sign-in history.
- **macOS's own traffic**, such as push notifications and certificate checks.
- **Account standing.** Guard only handles the network; it can't promise how Anthropic treats any IP. Follow Anthropic's terms and local rules.

### Not available during protection

- Signing in to Claude in an external browser (stop protection first)
- `sudo` inside Claude
- Local, company and school networks (can be allowed one by one)

Some technical limits (UDP, QUIC, IPv6, etc.) fall back automatically and are usually unnoticeable. Full list: **[BOUNDARIES.md](BOUNDARIES.md)** (Chinese).

### Not tested yet

Sleep/wake and restart, hours of continuous use, a real public-IP change, other Macs and macOS versions, other VPN and proxy apps, native IPv6 networks.

<details>
<summary>Best to turn off before starting (Guard notices most of these)</summary>

| Turn off | Why |
|---|---|
| Claude Desktop (⌘Q) | It must be opened from Guard to be protected |
| claude.ai tabs and Claude extensions in browsers | Otherwise they get blocked and keep warning |
| `claude` in Terminal or editors | Not protected |
| "System proxy" switch in proxy apps | Guard can't confirm which network that traffic uses. **A system-wide VPN (TUN mode) is fine** |
| Company/school security software with a "DNS proxy" | It may take over name lookups. See System Settings › Network › Filters & Proxies |

</details>

<details>
<summary>What Guard contacts</summary>

No analytics, no server of its own. To check the IP it uses these public services, which see the selected network's IP:

- Cloudflare, AWS `checkip`, ipify, icanhazip: read the public IP
- `ip.net.coffee`: third-party test site, only when you click
- `claude.ai`, `api.anthropic.com`: only when you click "Test Claude connection"

</details>

---

## Update and uninstall

Stop protection, quit Guard and Claude, then paste into Terminal:

**Update**

```bash
cd ~/ClaudeNetworkGuard && git pull && ./install.sh
```

**Uninstall**

```bash
cd ~/ClaudeNetworkGuard && ./uninstall.sh
```

## More

| To learn | See |
|---|---|
| Every boundary and test | [BOUNDARIES.md](BOUNDARIES.md) |
| How it works | [ARCHITECTURE_USB.md](ARCHITECTURE_USB.md) |
| What each version tested | [VERIFICATION.md](VERIFICATION.md) |
| Verify it yourself | [ACCEPTANCE.md](ACCEPTANCE.md) |
