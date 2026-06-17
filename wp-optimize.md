# Skill: wp-optimize

## Trigger
Invoke when the user says: "wp-optimize", "optimizar wordpress", "diagnosticar servidor wordpress", "wordpress lento", "wordpress performance", "optimize wordpress server", or similar.

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
```

### Key metrics to compute
- **RAM pressure**: `used / total > 85%` = warning, `swap_used > 50% of swap_total` = critical
- **Worker overload**: `workers × avg_size_mb > available_ram_mb × 0.9` = critical
- **Safe max_children**: `floor((available_ram_mb × 0.75) / avg_size_mb)` — never below 2, never above 32
- **Bot ratio**: `add_to_cart_requests / total_last_5000 > 20%` = suspicious
- **load-styles latency**: `> 3s` = problem, `504/timeout` = critical
- **Load average vs CPUs**: `load_1min / nproc > 2` = critical

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
