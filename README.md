# wp-optimize — Claude Code Skill

A Claude Code skill for complete WordPress server optimization. Connects via SSH to any WordPress server, runs a full diagnostic, applies fixes adapted to the detected stack, and verifies the improvement.

Works on any hosting provider: Raiola, Hostinger, SiteGround, Kinsta, DigitalOcean, any VPS or shared host with SSH access.

## What it does

**Phase 1 — Connection:** Detects Windows/Linux/Mac and picks the right SSH method (plink, sshpass, or ssh key). Handles base64 encoding for complex remote commands.

**Phase 2 — Detection:** Identifies control panel (cPanel, Plesk, HestiaCP, VestaCP, DirectAdmin, none), web server (Apache / nginx / LiteSpeed), PHP handler (FPM / mod_php / CGI), and locates all WordPress installations.

**Phase 3 — Diagnosis:** 12 key metrics — load average, RAM, swap, PHP-FPM worker count, memory per worker, active cache plugin, WordPress version, active plugin count, recent PHP errors, bot traffic patterns, admin CSS response time, CONCATENATE_SCRIPTS status.

**Phase 4 — Report:** Prioritized issue table (Critical / Warning / Info) with proposed fix for each issue. Asks for confirmation before applying anything.

**Phase 5 — Fixes:** 7 adaptive fixes:
- PHP-FPM `pm.max_children` (calculated safe value based on available RAM)
- `CONCATENATE_SCRIPTS = false` in wp-config (fixes wp-admin CSS/JS when FPM is saturated)
- nginx bot blocking for scraper patterns (or `.htaccess` fallback on shared hosting)
- Cache plugin activation and configuration
- PHP memory limit increase
- xmlrpc.php blocking
- Safe plugin deactivation for PHP fatal errors

**Phase 6 — Verification:** Re-runs key metrics and shows a before/after comparison table.

## Supported stacks

| Component | Supported values |
|---|---|
| OS client | Windows (plink), Linux, macOS |
| Web server | Apache, nginx, nginx+Apache (reverse proxy), LiteSpeed, OpenLiteSpeed |
| PHP handler | PHP-FPM, mod_php |
| Control panel | cPanel, Plesk, HestiaCP, VestaCP, DirectAdmin, none |
| SSH access | root, sudo user, restricted shared hosting |

## Installation

### Option A — Install script (Linux/macOS)

```bash
git clone https://github.com/buenroger/claude-wp-optimize.git
cd claude-wp-optimize
chmod +x install.sh && ./install.sh
```

### Option B — Install script (Windows PowerShell)

```powershell
git clone https://github.com/buenroger/claude-wp-optimize.git
cd claude-wp-optimize
.\install.ps1
```

### Option C — Manual

Copy `wp-optimize.md` to your Claude Code skills directory:

- **Linux/macOS:** `~/.claude/skills/wp-optimize.md`
- **Windows:** `C:\Users\YOUR_USER\.claude\skills\wp-optimize.md`

## Usage

In any Claude Code session:

```
/wp-optimize
```

Claude will ask for SSH credentials, then guide you through the full optimization process.

## Updating

```bash
cd claude-wp-optimize
git pull
./install.sh   # or .\install.ps1 on Windows
```

## Requirements

- [Claude Code](https://claude.ai/code) installed
- SSH access to the WordPress server
- WP-CLI installed on the server (recommended, not required)
