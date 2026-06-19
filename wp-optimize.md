---
name: wp-optimize
description: "Full WordPress server optimization via SSH. Connects to any WordPress server, runs a 12-metric diagnostic, presents a prioritized issue report, applies fixes adapted to the detected stack (nginx/Apache/LiteSpeed, cPanel/Plesk/VestaCP/HestiaCP/DirectAdmin/none), and verifies the improvement. Use when user says /wp-optimize, wordpress lento, optimizar wordpress, wordpress performance, or similar."
user-invokable: true
argument-hint: "[ssh-host]"
license: MIT
metadata:
  author: buenroger
  version: "1.2.0"
  category: wordpress
---

## Goal
Connect to any WordPress server via SSH, run a full diagnostic, present a prioritized issue report, apply approved fixes adapted to the detected stack, and verify the improvement. Works on any hosting: Raiola, Hostinger, SiteGround, Kinsta, DigitalOcean, any VPS or shared host with SSH.

---

## PHASE 1 — SSH Connection Setup

### 1.1 Collect credentials
Ask the user for:
- **Host** (IP or domain)
- **User** (root, or non-root with sudo)
- **Password or key path**
- **Port** (default 22)

Check if there is an `ssh_config.txt` or `.env` file in the project directory first before asking.

### 1.2 Detect connection method (Windows vs Linux/Mac)
```
If running on Windows:
  - Check if plink is available: Get-Command plink
  - If yes: use plink pattern
      echo y | plink -ssh -pw "PASSWORD" -batch USER@HOST "COMMAND"
  - If no: try ssh with expect, or ask user to run ! ssh USER@HOST
If running on Linux/Mac:
  - Check if sshpass is available: which sshpass
  - If yes: sshpass -p 'PASSWORD' ssh -o StrictHostKeyChecking=no USER@HOST "COMMAND"
  - If no: use ssh with key, or prompt user to run ! ssh USER@HOST
```

**For commands with single quotes on Windows/plink**, encode via base64:
```powershell
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('COMMAND'))
echo y | plink -ssh -pw "PASSWORD" -batch USER@HOST "echo $b64 | base64 -d | bash"
```

**For PHP file modifications**, write a PHP script encoded as base64:
```powershell
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('<?php ... ?>'))
echo y | plink -ssh -pw "PASSWORD" -batch USER@HOST "echo $b64 | base64 -d > /tmp/wpfix.php && php /tmp/wpfix.php && rm /tmp/wpfix.php"
```

### 1.3 Test connection
Run: `echo "CONNECTED" && whoami && hostname`
If it fails, check port, try port 2222 (Hostinger), 2083 (cPanel SSH), ask user to verify firewall.

Store the working SSH command pattern as `$SSH` for the rest of the session.

---

## PHASE 2 — Environment Detection

Run all detections in a single SSH call where possible to minimize round-trips.

### 2.1 Detect control panel
```bash
[ -d /usr/local/hestia ] && echo "PANEL=HestiaCP" || \
[ -d /usr/local/vesta ] && echo "PANEL=VestaCP" || \
[ -f /usr/local/cpanel/cpanel ] && echo "PANEL=cPanel" || \
[ -d /usr/local/psa ] && echo "PANEL=Plesk" || \
[ -f /usr/local/directadmin/directadmin ] && echo "PANEL=DirectAdmin" || \
echo "PANEL=none"
```

### 2.2 Detect web server
```bash
systemctl is-active nginx httpd apache2 lsws 2>/dev/null
nginx -v 2>&1; httpd -v 2>&1; apache2 -v 2>&1; /usr/sbin/lshttpd -v 2>&1
```
Priority: if LiteSpeed/OpenLiteSpeed is active → LiteSpeed stack. Else nginx+Apache (reverse proxy) or Apache alone or nginx alone.

### 2.3 Detect PHP handler and version
```bash
php -v 2>/dev/null | head -1
# Check FPM
systemctl list-units --type=service | grep -iE 'php.*fpm'
ps aux | grep -E 'php-fpm|php[0-9].*fpm' | grep -v grep | head -3
# Check mod_php
httpd -M 2>/dev/null | grep php; apache2ctl -M 2>/dev/null | grep php
```

### 2.4 Locate WordPress installations
```bash
find /home /var/www /srv/www /usr/share/nginx/html -name "wp-config.php" \
  -not -path "*/wp-content/*" -not -path "*/wp-admin/*" 2>/dev/null | head -10
```
If multiple sites found, ask user which one(s) to optimize.

### 2.5 Detect WP-CLI
```bash
which wp 2>/dev/null || which /usr/local/bin/wp 2>/dev/null
```
Set `$WPCLI="wp --path=WP_ROOT --allow-root"` for all subsequent WP-CLI calls.

### 2.8 Verify object cache integrity (not just presence)
A site can have `wp_using_ext_object_cache() === true` while the actual caching backend is dead — this silently breaks every plugin that relies on transients (payment gateways, shipping APIs, tracking pixels), because each one *thinks* it's caching but nothing survives between requests. Always verify the drop-in actually works, don't just check it exists:

```bash
# Does a drop-in exist?
ls -la WP_ROOT/wp-content/object-cache.php 2>/dev/null

# If it's a LiteSpeed Cache drop-in, the litespeed-cache PLUGIN must also be present —
# the drop-in self-disables on the frontend if the plugin folder is missing
$WPCLI plugin list --allow-root --fields=name | grep -i litespeed
head -5 WP_ROOT/wp-content/object-cache.php | grep -i "Plugin Name"

# Sanity check: does wp_using_ext_object_cache() agree with reality?
$WPCLI eval 'echo wp_using_ext_object_cache() ? "TRUE" : "FALSE";' --allow-root
```
If the drop-in's header names a caching plugin (LiteSpeed Cache, Redis Object Cache, W3TC, etc.) that is **not** in the active/installed plugin list, the drop-in is orphaned — almost always a leftover from a previous caching stack (e.g. site migrated from LiteSpeed Cache to WP Rocket and nobody removed the old drop-in). This is a CRITICAL finding: it cascades into making every other plugin's transient-based caching silently fail. See **FIX I**.

### 2.9 Check whether Redis/Memcached actually has a running service, not just a PHP module
`php -m | grep -iE 'redis|memcache'` only proves the *client library* is compiled in — it says nothing about whether a server is reachable. On budget shared hosting it's common to have the module but no service (Redis/Memcached are usually gated to higher hosting tiers). Always verify with an actual connection attempt before recommending or assuming object-cache-backed gains are available:
```bash
cat > /tmp/test_redis.php << 'EOF'
<?php
$r = new Redis();
try {
    echo $r->connect('127.0.0.1', 6379, 1) ? "CONNECTED\n" : "FAILED\n";
} catch (Exception $e) {
    echo "EXCEPTION: " . $e->getMessage() . "\n";
}
EOF
timeout 10 php /tmp/test_redis.php; rm -f /tmp/test_redis.php
```
If this times out / fails, say so plainly: persistent object caching is not available without a hosting plan change, and set expectations accordingly before investing time chasing per-request DB query counts further (see FIX M's ceiling note).

### 2.6 Detect PHP-FPM pool config path
```bash
# Varies by panel and distro:
# HestiaCP/VestaCP: /etc/opt/remi/phpXX/php-fpm.d/DOMAIN.conf
# cPanel: /opt/cpanel/ea-phpXX/root/etc/php-fpm.d/
# Plesk: /etc/php/X.X/fpm/pool.d/
# DirectAdmin: /etc/php/X.X/fpm/pool.d/ or /usr/local/directadmin/data/...
# Generic: /etc/php-fpm.d/ or /etc/php/X.X/fpm/pool.d/
find /etc -name "*.conf" 2>/dev/null | xargs grep -l "pm = " 2>/dev/null | grep -v example | head -5
```

### 2.7 Detect nginx custom config location (if nginx present)
```bash
# HestiaCP/VestaCP: /home/USER/conf/web/snginx.DOMAIN.conf
# cPanel: /etc/nginx/conf.d/DOMAIN.conf or /etc/nginx/sites-enabled/DOMAIN
# Plesk: /etc/nginx/conf.d/DOMAIN.conf
# Generic: /etc/nginx/sites-enabled/ or /etc/nginx/conf.d/
```

---

## PHASE 3 — Health Diagnostic

Run as a single SSH call:

```bash
echo "=== UPTIME ===" && uptime
echo "=== RAM ===" && free -m
echo "=== SWAP ===" && swapon --show
echo "=== DISK ===" && df -h /
echo "=== FPM WORKERS ===" && ps aux | grep -E 'php.*fpm' | grep -v 'master\|grep' | wc -l
echo "=== FPM WORKER SIZE (MB) ===" && ps aux | grep -E 'php.*fpm' | grep -v 'master\|grep' | awk '{sum+=$6; n++} END {if(n>0) printf "%.0f\n", sum/n/1024; else print "0"}'
echo "=== WP VERSION ===" && $WPCLI core version 2>/dev/null
echo "=== ACTIVE PLUGINS ===" && $WPCLI plugin list --status=active --format=count 2>/dev/null
echo "=== CACHE PLUGIN ===" && $WPCLI plugin list --status=active --format=table --fields=name 2>/dev/null | grep -iE 'cache|rocket|w3|swift|breeze|litespeed|sg-cachepress'
echo "=== PHP ERRORS (last 20) ===" && tail -20 ERROR_LOG 2>/dev/null
echo "=== TOP IPS (last 5000 req) ===" && tail -5000 ACCESS_LOG 2>/dev/null | awk '{print $1}' | sort | uniq -c | sort -rn | head -10
echo "=== BOT ADD-TO-CART ===" && tail -5000 ACCESS_LOG 2>/dev/null | grep 'add-to-cart' | wc -l
echo "=== LOAD STYLES TEST ===" && curl -sk -o /dev/null -w '%{http_code} %{time_total}' "https://DOMAIN/wp-admin/load-styles.php?c=1&dir=ltr&load%5Bchunk_0%5D=dashicons,common" 2>/dev/null
echo "=== CONCATENATE_SCRIPTS ===" && grep 'CONCATENATE_SCRIPTS' WP_CONFIG 2>/dev/null || echo "not set (default: true)"
echo "=== MEMORY LIMIT ===" && $WPCLI eval 'echo WP_MEMORY_LIMIT;' 2>/dev/null
echo "=== WP-CRON BACKLOG (overdue events) ===" && $WPCLI cron event list --allow-root --format=csv 2>/dev/null | grep -c ',now,'
echo "=== WP-CRON TOTAL EVENTS ===" && $WPCLI cron event list --allow-root --format=count 2>/dev/null
echo "=== CART/CHECKOUT TIMING (WooCommerce only) ===" && curl -sk --max-time 20 -o /dev/null -w 'cart: %{http_code} %{time_total}s\n' "https://DOMAIN/cart/" 2>/dev/null
```

### Key metrics to compute
- **RAM pressure**: `used / total > 85%` = warning, `swap_used > 50% of swap_total` = critical
- **Worker overload**: `workers × avg_size_mb > available_ram_mb × 0.9` = critical
- **Safe max_children**: `floor((available_ram_mb × 0.75) / avg_size_mb)` — never below 2, never above 32
- **Bot ratio**: `add_to_cart_requests / total_last_5000 > 20%` = suspicious
- **load-styles latency**: `> 3s` = problem, `504/timeout` = critical
- **Load average vs CPUs**: `load_1min / nproc > 2` = critical
- **WP-Cron backlog**: more than ~15-20 overdue (`,now,`) events = warning; this number must be near-zero before attempting FIX H (moving cron off page-load), or the first real-cron run can time out / 503 trying to process the backlog synchronously
- **Cart/checkout vs home delta**: if cart/checkout is 3x+ slower than the home page on a WooCommerce site, suspect synchronous third-party API calls (payment gateways, shipping rate plugins, tracking pixels) rather than server resources — profile with the technique in **FIX K** before touching PHP-FPM or server config
- **Cart/checkout test methodology**: always test with a persistent cookie jar (`curl -c jar.txt -b jar.txt`), not a bare curl — each cookie-less request creates a brand-new anonymous WooCommerce session, which can mask or distort real timing. Run at least 2-3 requests with the same jar; the first may be a genuine cache miss.

---

## PHASE 4 — Issue Report

Present findings as a prioritized table before applying any fix:

```
## WordPress Server Health Report — DOMAIN
Diagnosed: DATE | Stack: WEBSERVER + PHP X.X (FPM) | Panel: PANEL

### CRITICAL
| # | Issue | Impact | Fix |
|---|---|---|---|
| 1 | PHP-FPM max_children=32 but only 6 safe workers (RAM) | OOM/swap crash | Reduce to N |
| 2 | load-styles.php timeout (504) — admin CSS not loading | wp-admin broken | CONCATENATE_SCRIPTS=false |

### WARNING
| # | Issue | Impact | Fix |
|---|---|---|---|
| 3 | Bot traffic: 340 add-to-cart hits in last 5000 req | Consumes all PHP workers | nginx 429 block |
| 4 | No page cache active | Every request hits PHP | Install/activate cache plugin |

### INFO
| # | Issue | Impact | Fix |
|---|---|---|---|
| 5 | WP_DEBUG not set | Errors invisible | Enable temporarily for debugging |
| 6 | iThemelandCo plugin PHP Warning on every request | Minor overhead | Update or deactivate plugin |
```

Ask: **"¿Aplico todos los fixes críticos y warnings? O dime cuáles quieres (1,2,3...)."**

---

## PHASE 5 — Fix Application

Apply each approved fix. Adapt commands to detected stack.

### FIX A: Reduce PHP-FPM max_children

Calculate safe value: `safe_n = floor((available_ram_mb * 0.75) / avg_worker_mb)`
Clamp: min 2, max 32.

```bash
# Find the pool config for this domain
POOL_CONF=$(grep -rl "pm = ondemand\|pm = dynamic\|pm = static" /etc/php-fpm.d/ /etc/opt/remi/*/php-fpm.d/ /etc/php/*/fpm/pool.d/ 2>/dev/null | xargs grep -l "DOMAIN\|WP_USER" 2>/dev/null | head -1)

# Edit
sed -i "s/pm.max_children = [0-9]*/pm.max_children = SAFE_N/" "$POOL_CONF"

# Verify
grep 'pm.max_children' "$POOL_CONF"

# Reload (use reload not restart to avoid dropping connections)
# Detect service name:
systemctl list-units --type=service | grep -i 'php.*fpm' | awk '{print $1}' | head -1
systemctl reload PHP_FPM_SERVICE
```

**Stack-specific pool config locations:**
- HestiaCP/VestaCP: `/etc/opt/remi/phpXX/php-fpm.d/DOMAIN.conf`
- cPanel (EasyApache): `/opt/cpanel/ea-phpXX/root/etc/php-fpm.d/DOMAIN.conf`
- Plesk: `/etc/php/X.X/fpm/pool.d/DOMAIN.conf`
- DirectAdmin: `/etc/php/X.X/fpm/pool.d/DOMAIN.conf`
- Generic Ubuntu/Debian: `/etc/php/X.X/fpm/pool.d/www.conf`
- Generic RHEL/AlmaLinux: `/etc/php-fpm.d/www.conf`

### FIX B: Disable script concatenation (admin CSS/JS fix)

Add to `wp-config.php` after the `WP_SITEURL` or `table_prefix` line:

```php
<?php
$file = 'WP_CONFIG_PATH';
$content = file_get_contents($file);
$new = "define( 'CONCATENATE_SCRIPTS', false );";
if (strpos($content, $new) === false) {
    // Insert after <?php opening or after DB_HOST definition
    $anchor = "define( 'DB_HOST'";
    $pos = strpos($content, $anchor);
    if ($pos !== false) {
        $end = strpos($content, ';', $pos) + 1;
        $content = substr($content, 0, $end) . "\n" . $new . substr($content, $end);
    } else {
        $content = str_replace("<?php\n", "<?php\n" . $new . "\n", $content);
    }
    file_put_contents($file, $content);
    echo 'OK: CONCATENATE_SCRIPTS=false added';
} else { echo 'Already set'; }
```

Encode this as base64 and execute via `php` on the server.

Verify: `curl -sk -o /dev/null -w '%{http_code}' https://DOMAIN/wp-admin/css/common.min.css` → should return 200 quickly.

### FIX C: Nginx bot blocking (add-to-cart pattern)

Only apply if nginx is in the stack. Write to the nginx custom config file for the domain.

```nginx
# Block bot scraping of paginated shop + add-to-cart
if ($request_uri ~ "^/SHOP_SLUG/page/[0-9]+/.*add-to-cart=") {
    return 429;
}
```

**Note:** Use `$request_uri` (includes query string), NOT `$uri`. Do NOT use chained `set` variable blocks — they fail silently in nginx `if` context.

Detect shop slug from WooCommerce:
```bash
$WPCLI eval 'echo wc_get_page_permalink("shop");' 2>/dev/null
```
Or grep access log for the paginated pattern.

After writing the file:
```bash
nginx -t && nginx -s reload
```

Test: `curl -sk -o /dev/null -w '%{http_code}' 'https://DOMAIN/tienda/page/5/?add-to-cart=100'` → should be 429.

For **cPanel/Plesk** without direct nginx config access, use `.htaccess` mod_rewrite instead:
```apache
# In .htaccess, before WordPress rules
RewriteCond %{QUERY_STRING} add-to-cart=
RewriteCond %{REQUEST_URI} /page/[0-9]+/
RewriteRule ^ - [F,L]
```

### FIX D: Activate or configure cache plugin

**If LiteSpeed Cache installed but inactive (LiteSpeed/OLS server):**
```bash
$WPCLI plugin activate litespeed-cache
$WPCLI litespeed-option set cache 1
$WPCLI litespeed-option set cache-browser 1
```

**If on Apache without LiteSpeed**, recommend WP Super Cache (free) or WP Rocket (paid):
```bash
# WP Super Cache
$WPCLI plugin install wp-super-cache --activate
$WPCLI eval 'wp_super_cache_enable();'
# Then verify: wp-content/cache/supercache/ gets populated
```

**If Redis/Memcached available on server:**
```bash
# Check
php -m | grep -iE 'redis|memcache'
# If present, activate object cache:
$WPCLI plugin install redis-cache --activate
$WPCLI redis enable
```

### FIX E: Increase PHP memory limit in wp-config

Only if WP reports memory limit < 256M:
```php
define('WP_MEMORY_LIMIT', '256M');
define('WP_MAX_MEMORY_LIMIT', '512M');
```

### FIX F: Block xmlrpc.php if not needed

```bash
# Check if used (WooCommerce, JetPack, MainWP may need it)
$WPCLI eval 'echo class_exists("Jetpack") ? "Jetpack:yes" : "Jetpack:no";' 2>/dev/null
```

If not needed, add to nginx custom conf:
```nginx
location = /xmlrpc.php { deny all; return 444; }
```
Or in `.htaccess`:
```apache
<Files xmlrpc.php>
  Order Deny,Allow
  Deny from all
</Files>
```

### FIX G: Fix WP admin 500 caused by plugin PHP fatal errors

If PHP fatal errors found in error log pointing to a specific plugin:
```bash
# Safely deactivate via WP-CLI (bypasses WP bootstrap if needed)
$WPCLI plugin deactivate PLUGIN_NAME --skip-plugins
```

### FIX H: Move WP-Cron off page-load to a real server cron job

**Never do this in one step.** Disabling `DISABLE_WP_CRON` while there's a backlog of overdue events causes WordPress to try to process the entire backlog synchronously on the very first real cron hit — this can 503/timeout the site for 30-60+ seconds. Sequence matters:

1. **Check the backlog first**: `$WPCLI cron event list --allow-root --format=csv | grep -c ',now,'`. If more than ~15-20, clean it up before proceeding (see the orphaned-hook cleanup below).
2. **Clean genuinely orphaned cron hooks** — events whose callback no longer exists because the plugin was uninstalled (common after migrating away from Jetpack, Elementor, Divi, UpdraftPlus, WPCode, MonsterInsights, Siteground Optimizer, etc.). Cross-reference, don't guess:
   ```bash
   # List unique hooks currently scheduled
   $WPCLI cron event list --allow-root --fields=hook --format=csv | sort -u

   # For each suspicious hook, confirm no plugin/theme file references it anywhere on disk
   grep -rl "HOOK_NAME" WP_ROOT/wp-content/plugins WP_ROOT/wp-content/themes WP_ROOT/wp-content/mu-plugins 2>/dev/null

   # If truly no match anywhere, delete it — it will never run anyway
   $WPCLI cron event delete 'HOOK_NAME' --allow-root
   ```
   Don't delete an event just because it's a duplicate or one-off "Non-repeating" entry without checking — some are legitimate one-shot tasks that simply haven't fired yet (real traffic clears those naturally). Only delete what's confirmed orphaned (no code on disk) or confirmed stale duplicates of the same one-shot hook.
3. **Create the real cron job** — via the host's panel (hPanel, cPanel "Cron Jobs", Plesk "Scheduled Tasks") if no root crontab access, or `crontab -e` if root:
   ```bash
   */5 * * * * wget -q -O /dev/null "https://DOMAIN/wp-cron.php?doing_wp_cron" >/dev/null 2>&1
   ```
4. **Verify the real cron endpoint responds before disabling the page-load trigger**:
   ```bash
   curl -sk -o /dev/null -w 'code=%{http_code} time=%{time_total}s\n' --max-time 30 "https://DOMAIN/wp-cron.php?doing_wp_cron"
   ```
5. **Only then** add to wp-config.php (back up first):
   ```bash
   cp WP_ROOT/wp-config.php WP_ROOT/wp-config.php.bak-precron
   ```
   ```php
   define( 'DISABLE_WP_CRON', true );
   ```
6. **Verify with a timeout safety net**, never a bare curl that could hang:
   ```bash
   curl -sk -o /dev/null -w 'code=%{http_code} time=%{time_total}s\n' --max-time 20 "https://DOMAIN/"
   ```
   If this is slow/errors (503, 30s+), **immediately restore** `cp WP_ROOT/wp-config.php.bak-precron WP_ROOT/wp-config.php` — the backlog wasn't actually cleared, go back to step 1.

### FIX I: Remove an orphaned object-cache.php drop-in

If 2.8 found a drop-in whose backing plugin isn't installed, it's dead weight that's actively breaking every transient-dependent plugin on the site (payment gateways, shipping rate caches, tracking pixel config — see FIX J). Safe to remove:

```bash
cp WP_ROOT/wp-content/object-cache.php WP_ROOT/wp-content/object-cache.php.bak-orphan
rm WP_ROOT/wp-content/object-cache.php
$WPCLI eval 'echo wp_using_ext_object_cache() ? "TRUE" : "FALSE";' --allow-root   # should now print FALSE
```
After removal, WordPress falls back to options-table-backed transients, which actually persist. Re-test any cart/checkout slowness *after* this fix, before chasing individual plugins — it's often the real root cause behind seemingly unrelated "plugin X calls its API on every page load" symptoms. Note that some hosts (e.g. Hostinger's server-level LiteSpeed integration) can silently recreate this drop-in later; if performance regresses again, re-check 2.8.

### FIX J: Extend a too-short transient cache on a third-party API plugin

Real-time shipping rate plugins (Envia, Packlink), payment gateways (PayPal Payments, Stripe), and tracking pixels (Meta/Facebook Conversions API) often cache their external API responses in a transient with a short TTL (commonly 10 minutes) baked into the plugin's own code. On a site with sparse cart/checkout traffic, every visit can be a cache miss, adding 1-3+ seconds per call. Don't patch the plugin's files (lost on update). Instead:

1. **Confirm caching is actually broken first** (run FIX I's check — a dead object-cache.php drop-in causes exactly this symptom across multiple plugins simultaneously; fix that before touching individual plugins).
2. **Look for an official non-blocking/async filter** before writing a workaround — well-maintained plugins often ship one specifically for this. Example, Meta/Facebook for WooCommerce:
   ```bash
   grep -rn "non_blocking\|blocking.*false" WP_ROOT/wp-content/plugins/facebook-for-woocommerce/includes/API.php
   ```
   ```php
   // mu-plugin or Code Snippets — official filter, documented by the plugin itself
   add_filter('wc_facebook_pixel_events_non_blocking', '__return_true');
   ```
3. **If no official filter exists**, find the transient key and prefix in the plugin's code (`grep -rn "set_transient\|new Cache(" PLUGIN_DIR`), then re-extend it via whatever value-filter the plugin exposes (many call `apply_filters` right after caching the value — hook that filter and call `set_transient()` again with a longer TTL under the same key). Example, PayPal Payments:
   ```php
   add_filter('woocommerce_paypal_payments_seller_status', function ($status) {
       if ($status instanceof \WooCommerce\PayPalCommerce\ApiClient\Entity\SellerStatus) {
           set_transient('ppcp-seller-status-seller_status', $status, HOUR_IN_SECONDS);
       }
       return $status;
   });
   ```
4. Always disclose the trade-off to the user (slower to reflect upstream changes, e.g. PayPal capability changes take up to the new TTL to show) and confirm before installing.
5. Save the snippet to a file for the user to install via a snippets plugin (Code Snippets, WPCode) rather than editing core plugin files or wp-config.php directly — survives plugin updates, easy to disable/audit.

### FIX K: Diagnostic technique — profile slow page loads with a temporary mu-plugin

When a specific page (cart, checkout) is slow but server resources (RAM, CPU, load average) look healthy, the cause is usually synchronous work inside the page's own hooks — most often outbound HTTP calls to third-party APIs. Standard tools (curl timing, error log) won't show *which* plugin or hook is responsible. A temporary mu-plugin will, without needing Xdebug or paid APM:

**Always explain this technique to the user and get explicit confirmation before installing it** — it is live code running on the production site, even though scoped and temporary.

```php
<?php
// wp-content/mu-plugins/zzz-profile-temp.php — only activates with ?profile_run=1
if (!isset($_GET['profile_run'])) return;
$GLOBALS['__prof_start'] = microtime(true);
add_action('http_api_debug', function($response, $context, $class, $args, $url) {
    $t = microtime(true) - $GLOBALS['__prof_start'];
    $blocking = isset($args['blocking']) ? ($args['blocking'] ? 'blocking' : 'NON-BLOCKING') : 'blocking(default)';
    file_put_contents('/tmp/profile_urls.txt', sprintf("[t=%.3fs] [%s] %s\n", $t, $blocking, $url), FILE_APPEND);
}, 10, 5);
add_action('shutdown', function() {
    file_put_contents('/tmp/profile_urls.txt', sprintf("TOTAL: %.3fs\n", microtime(true) - $GLOBALS['__prof_start']), FILE_APPEND);
}, 9999);
```

Usage:
```bash
rm -f /tmp/profile_urls.txt
curl -sk --max-time 30 -o /dev/null -w 'total=%{time_total}s\n' "https://DOMAIN/cart/?profile_run=1"
cat /tmp/profile_urls.txt
```
This hooks `http_api_debug` (fires on every `wp_remote_*` call) and logs the elapsed time and URL of each one, plus whether it was blocking. Read top-to-bottom: large gaps between timestamps point to the slow call. Run it twice in a row — if the same external calls reappear on the second run with similar timing, caching isn't holding (see FIX I/J); if they disappear, caching is working and the remaining time is genuine PHP/DB processing.

**Always remove the file immediately after reading the result**, even between iterations:
```bash
rm -f WP_ROOT/wp-content/mu-plugins/zzz-profile-temp.php /tmp/profile_urls.txt
```
Never leave a profiling mu-plugin installed — it's a query-string-gated backdoor by design and shouldn't persist past the diagnostic session.

A broader variant hooks the `all` action instead of `http_api_debug` to catch slow non-HTTP hooks (e.g. a slow DB query inside a hook with no outbound request), logging any gap between consecutive hook firings above a threshold (e.g. 50ms) — useful when FIX K's HTTP-only trace comes up clean but the page is still slow.

### FIX L: Attribute DB query count to the responsible plugin (no guessing, no bisection)

When `get_num_queries()` shows a high count on a slow page (e.g. 300-400+ on a single WooCommerce cart/checkout load) and 50+ plugins are active, don't audit plugin source code one by one and don't deactivate-and-remeasure 50 times — hook the `query` filter once and attribute every query to its caller via `debug_backtrace()`. One page load gives a precise ranking:

```php
<?php
// wp-content/mu-plugins/zzz-profile-bysource.php — only activates with ?profile_run=1
if (!isset($_GET['profile_run'])) return;
$GLOBALS['__q_by_source'] = [];
add_filter('query', function($sql) {
    $trace = debug_backtrace(DEBUG_BACKTRACE_IGNORE_ARGS);
    $source = 'core/unknown';
    foreach ($trace as $frame) {
        if (!isset($frame['file'])) continue;
        if (preg_match('#/wp-content/plugins/([^/]+)/#', $frame['file'], $m)) { $source = 'plugin: ' . $m[1]; break; }
        if (preg_match('#/wp-content/themes/([^/]+)/#', $frame['file'], $m)) { $source = 'theme: ' . $m[1]; break; }
    }
    $GLOBALS['__q_by_source'][$source] = ($GLOBALS['__q_by_source'][$source] ?? 0) + 1;
    return $sql;
});
add_action('shutdown', function() {
    arsort($GLOBALS['__q_by_source']);
    $out = "TOTAL: " . array_sum($GLOBALS['__q_by_source']) . "\n\n";
    foreach ($GLOBALS['__q_by_source'] as $source => $count) $out .= sprintf("%4d  %s\n", $count, $source);
    file_put_contents('/tmp/profile_bysource.txt', $out);
}, 9999);
```
This doesn't need `SAVEQUERIES` defined — `get_num_queries()` and counting via the `query` filter work regardless. Run it, read `/tmp/profile_bysource.txt`, remove the mu-plugin and the temp file immediately (same discipline as FIX K).

Once a plugin is identified as a top contributor, get the exact call site (not just the plugin name) by filtering the backtrace for that specific plugin's path and recording `file:line` instead of just the plugin slug — this finds the actual function (and from there, the actual hook it's attached to) instead of leaving it as a guess. Then judge case by case:
- **Necessary work** (active firewall/audit logging, a payment gateway's real cache-miss API call, WooCommerce's own cart/tax/shipping calculation) — leave alone, don't sacrifice security or correctness for query count.
- **Genuinely unconditional overhead** (a feature plugin checking its own settings on every single page load regardless of whether that page uses any of its features) — first look for an official setting/filter to scope or disable that code path; only consider FIX M if it's an autoload problem.

### FIX M: Fix "reverse autoload bloat" — small options forced into individual queries

The usual WordPress advice is "reduce autoloaded options, they bloat the bootstrap query." The opposite problem also exists and is just as costly: a plugin checking many small feature-toggle/telemetry options via `get_option()` with `autoload` explicitly `off` (or via options that don't exist as rows at all) forces one individual `SELECT ... WHERE option_name = 'X'` query per option, on every page load, instead of riding along in WordPress's single bulk autoload query that already runs regardless.

1. Get the exact option names FIX L's backtrace technique surfaced (or capture them directly — see the `query` filter regex variant: match `SELECT option_value FROM .* option_name = '([^']+)'` and log the captured key whenever the call stack passes through the suspect plugin).
2. Check what's actually in the DB for them:
   ```bash
   $WPCLI db query "SELECT option_name, autoload, LENGTH(option_value) FROM wp_options WHERE option_name IN ('key1','key2',...);" --allow-root
   ```
3. **Only options that actually exist with `autoload = off`** can be safely fixed — flip them:
   ```bash
   $WPCLI db query "UPDATE wp_options SET autoload='on' WHERE option_name IN ('key1','key2',...);" --allow-root
   ```
   This is safe and low-risk: it changes nothing about the option's value or behavior, only how WordPress fetches it.
4. **Options that don't exist as rows at all** (very common — a plugin calls `get_option('foo', $default)` for a setting the user never touched, so there's nothing to flip) **cannot be fixed this way.** Don't manually `INSERT` fake rows to fake an autoload entry — it's fragile (gets overwritten or duplicated the moment the plugin's own settings-save logic runs) and not a real fix. Say so plainly to the user: this specific cost is structural and only goes away with a real persistent object cache (Redis/Memcached — see 2.9), which doesn't change DB rows, it adds a request-spanning cache so the "does this exist" check itself stops hitting MySQL.
5. **Set expectations honestly.** On a page with 50+ active plugins each checking a handful of their own options, fixing 2-3 autoload flags will show up in a precise query-count diff but is unlikely to be measurable in wall-clock time (each such query costs low single-digit milliseconds; curl timing noise from network/TLS easily exceeds the gain). Report the query-count win as real and worth doing, without overstating the user-facing speed impact.

---

## PHASE 6 — Verification

Re-run core metrics and compare:

```bash
echo "=== POST-FIX HEALTH ===" && \
uptime && \
free -m && \
ps aux | grep -E 'php.*fpm' | grep -v 'master\|grep' | wc -l && \
curl -sk -o /dev/null -w 'admin-css: %{http_code} %{time_total}s\n' https://DOMAIN/wp-admin/css/common.min.css && \
curl -sk -o /dev/null -w 'home: %{http_code} %{time_total}s\n' https://DOMAIN/
```

Present as before/after table:

```
| Metric              | Before  | After   |
|---------------------|---------|---------|
| Load average (1m)   | 8.30    | 1.54    |
| RAM available       | 69 MB   | 859 MB  |
| Swap used           | 1.0 GB  | 354 MB  |
| PHP-FPM workers     | 41      | 4       |
| Admin CSS response  | 504     | 200     |
| Home response time  | 12.3s   | 0.4s    |
```

List any **remaining issues** not yet fixed (pending actions for the user, e.g., "consult fs2ps about sync frequency").

---

## ADAPTATION RULES

### Shared hosting (no root, cPanel/Plesk UI only)
- Cannot modify PHP-FPM pool → recommend user change PHP workers via panel UI
- Cannot modify nginx → use `.htaccess` for bot blocking and redirects
- Use WP-CLI if available, or wp-config.php edits via SFTP
- Focus on: cache plugin, CONCATENATE_SCRIPTS, memory limit, plugin audit

### LiteSpeed / OpenLiteSpeed stack
- LiteSpeed Cache plugin WILL do full page caching (unlike on Apache)
- Use `$WPCLI litespeed-purge all` after config changes
- PHP-FPM pool may be managed by lsphp process, not standard php-fpm
- Check: `ps aux | grep lsphp`

### Shared hosting without Redis/Memcached (verified via 2.9)
- There is a real, honest performance floor here: every `get_option()` call for a non-autoloaded or non-existent option costs a fresh MySQL round-trip on every single page load, with no way to cache it across requests.
- After fixing object-cache integrity (FIX I), cron (FIX H), and third-party API caching (FIX J), further gains from auditing individual plugins' query counts (FIX L/M) have steeply diminishing returns — each additional fix is typically 1-5 queries / a few ms, not seconds.
- Say this directly to the user once reached, rather than continuing to chase incremental plugin-by-plugin wins indefinitely: the two paths forward are (a) reduce the number of active plugins (a product decision, not a technical one) or (b) upgrade the hosting plan for a real persistent object cache. Don't let the user believe more SSH-side tuning will close that gap.

### Managed hosting (Kinsta, WP Engine, Flywheel)
- SSH access is usually non-root, restricted to the site user
- No access to nginx/server config
- Focus: WP-CLI commands, wp-config.php, plugin management
- These hosts typically have built-in caching — don't install a cache plugin that conflicts

### nginx-only stack (no Apache)
- `load-styles.php` goes through PHP-FPM via nginx fastcgi_pass, not proxy_pass
- PHP-FPM pool config is at `/etc/php/X.X/fpm/pool.d/`
- Reload: `systemctl reload phpX.X-fpm`

---

## SAFETY RULES

- **Never restart** PHP-FPM with `restart` during traffic — use `reload` to avoid dropping connections
- **Always run `nginx -t`** before `nginx -s reload` — a bad config takes down all sites
- **Never set max_children > (available_ram / avg_worker_size)** — swap exhaustion kills the server
- **Never deactivate WooCommerce** to "test" — use `--skip-plugins=woocommerce` with WP-CLI instead
- Before modifying wp-config.php, verify the change doesn't already exist: `grep 'CONSTANT_NAME' wp-config.php`
- For any destructive change (plugin deactivation, file modification), confirm with user first
- Keep a one-liner rollback ready before applying each fix
- **Always `cp file file.bak-DESCRIPTIVE-SUFFIX` before editing wp-config.php** (not git — most of these sites have no VCS). Restore immediately if verification fails after a change.
- **Never disable WP-Cron's page-load trigger before checking/clearing the overdue-event backlog** (see FIX H) — this caused a real 503 outage during testing when skipped.
- **Truncate, don't delete, large log files**: use `: > /path/error_log`, never `rm`. PHP may hold the file open; `rm` detaches the inode while PHP keeps writing into the now-unlinked file, so nothing is recoverable and disk space isn't even freed until the process cycles.
- **Always add `--max-time N` to verification curls** after a risky change (cron, FPM, wp-config edits). A hung request with no timeout can block the session for a minute or more if something went wrong — and a 503/30s+ response after a config change is itself the signal to roll back immediately, not retry.
- **`wp_using_ext_object_cache() === true` is not proof caching works** — verify the drop-in's backing plugin is actually installed (see 2.8 / FIX I) before trusting any transient-based diagnosis or fix.
- **When testing "does deactivating plugin X fix the slowness", reactivate immediately if it didn't help** — don't leave a production plugin deactivated while you keep investigating.
- A profiling mu-plugin (FIX K) is live code on a production site — always explain what it does and get explicit confirmation before installing it, even though it's temporary and query-string-gated.

---

## QUICK REFERENCE: Per-Panel PHP-FPM Service Names

| Panel | PHP-FPM Service Name Pattern |
|---|---|
| HestiaCP / VestaCP | `php81-php-fpm`, `php74-php-fpm` (remi) |
| cPanel (EasyApache) | `ea-php81` |
| Plesk | `php8.1-fpm` |
| DirectAdmin | `php-fpm81` or `php81-fpm` |
| Generic Ubuntu | `php8.1-fpm` |
| Generic RHEL/AlmaLinux | `php-fpm` or `php81-php-fpm` |
