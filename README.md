# php2shell

CVE-2026-109618 and CVE-2026-109619

A script to check whether a server's PHP is exposed to PHP2Shell, apply the temporary mitigations, and confirm the patch once it's installed.

## Quick start

```sh
curl -fsSLO https://raw.githubusercontent.com/5kr1pt/fix-to-php2shell/main/php2shell.sh

sh php2shell.sh check        # diagnosis only, changes nothing
sudo sh php2shell.sh fix     # mitigation: turn off session.upload_progress and reload
```

After the patch is out, update PHP (`check` prints the exact command for your distro) and run `check` again. It should end with `RESULTADO: CORRIGIDO`.

## Commands

| Command | What it does | Root? |
|---|---|---|
| `check` | Lists every PHP serving web traffic (php-fpm, mod_php, `php -S`) with version, patch status, mitigation status, and whether it's running and reachable on the network. **Changes nothing.** | no |
| `fix` | Writes `session.upload_progress.enabled = 0` to every PHP `conf.d`, tests the config and reloads php-fpm and Apache. | yes |
| `undo` | Removes what `fix` created and reloads. | yes |
| `block` | **Optional, stronger.** Blocks multipart POST requests at Apache/nginx. Cuts more of the attack surface but **breaks file uploads** unless you allowlist paths. | yes |
| `unblock` | Removes the multipart block. | yes |
| `docker <cmd> [container...]` | Runs any of the above inside running containers (docker or podman). No names = every running container with PHP. | — |

Exit codes, from lowest to highest risk: `0` patched · `1` vulnerable but stopped or localhost only · `2` vulnerable, mitigated · `3` vulnerable and exposed · `4` error. The last line is always `RESULTADO: <status>`.

> **Important:** none of these commands *fix* the bug. One of the PHP 8.6 release managers said on r/PHP that the ini change alone won't protect you and that you need to update PHP. The mitigations only shrink the attack surface until you can patch.
>
> <img src="img/release-manager-reddit.png" alt="PHP 8.6 release manager on r/PHP: INI files alone won't protect you. You need to update PHP." width="520" />
>
> Thread: https://www.reddit.com/r/PHP/comments/1xb2utu/upcoming_critical_php_security_release/

## `fix` — disable session.upload_progress

This is the low-risk mitigation. It turns off `session.upload_progress`, a feature almost no application uses, so uploads and forms keep working. It targets the path every public analysis (including the leaked write-up) points to, which needs that feature on. It does **not** cover a possible second path through the multipart parser.

```sh
sudo sh php2shell.sh fix      # apply
sudo sh php2shell.sh undo     # revert
```

## `block` — reject multipart POSTs (optional, stronger)

If a system can't be patched or taken offline yet, you can block `multipart/form-data` POSTs at the web server. This also covers the multipart-parser path, but **it breaks every upload** unless you allowlist the paths that need them.

```sh
# block everything (no uploads anywhere):
sudo sh php2shell.sh block

# keep uploads working on specific paths:
sudo PHP2SHELL_UPLOAD_PATHS="/wp-admin /api/upload" sh php2shell.sh block

sudo sh php2shell.sh unblock   # revert
```

- **Apache** (Debian and RHEL families): the rule is written to the server's include dir, validated and reloaded automatically. It matches any `Content-Type` starting with `multipart/`, so it isn't fooled by the `;` vs `,` boundary trick.
- **Allowlist** paths match at a path boundary: `/wp-admin` allows `/wp-admin` and `/wp-admin/...`, but not `/wp-admin-anything`.
- **nginx**: the block isn't applied automatically (nginx can't do it globally and safely). The command prints a snippet to paste into each `server {}` block.

## Docker and Kubernetes

`docker fix`/`docker block` are gone as soon as a container is recreated. To make `fix` stick, add this to the Dockerfile:

```dockerfile
RUN echo 'session.upload_progress.enabled = 0' > "$PHP_INI_DIR/conf.d/zz-php2shell.ini"
```

On Kubernetes you can mount it from a ConfigMap without rebuilding:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: php2shell-mitigation
data:
  zz-php2shell.ini: |
    session.upload_progress.enabled = 0
```

```yaml
# in the PHP container of the Deployment
volumeMounts:
  - name: php2shell
    mountPath: /usr/local/etc/php/conf.d/zz-php2shell.ini
    subPath: zz-php2shell.ini
volumes:
  - name: php2shell
    configMap:
      name: php2shell-mitigation
```

Then run `kubectl rollout restart deploy/<app>`. For the patch itself, update the base image and rebuild.

## Coverage

Works on Debian/Ubuntu, RHEL/Rocky/Alma, Alpine, the official `php:*` images, Remi, cPanel, Plesk and CloudLinux.

On Ubuntu the version doesn't change with the patch (it stays `8.3.6`), so the script looks for the CVE IDs in the package changelog. The network check only sees the host itself — if you removed external access at the proxy, firewall or DNS, the script can't tell, so it keeps the service as `EXPOSTO`. That's on purpose.

`check` also warns when:

- a pool forces `upload_progress = On`;
- the process is still running the old binary after an upgrade;
- the service is stopped but enabled at boot;
- php-fpm accepts FastCGI straight from the network (e.g. `0.0.0.0:9000`);
- the version is 8.1 or older, which won't get a PHP patch.

## Tests

Tested on Laravel 13 (`php:8.4-fpm` + nginx), WordPress (`wordpress:php8.3-apache`), Debian 13 with php-fpm, Ubuntu 24.04 with Apache + mod_php, Rocky 9 with httpd + php-fpm, Alpine (`php:8.3-fpm-alpine`) and Debian with systemd.

The test doesn't trust `ini_get()`. For `fix`, it sends a multipart POST with `PHP_SESSION_UPLOAD_PROGRESS` and checks whether PHP wrote the session file to disk — which happens before any application code, even on Laravel. For `block`, it confirms a multipart POST gets a 403, an allowlisted path still accepts uploads, and the rest of the site keeps working. This shows the mitigations are applied, not that they stop the exploit. There's no reliable public PoC.

```sh
tests/lab.sh up && tests/lab.sh test && tests/lab.sh down
```

## What we know so far

- Two RCEs in PHP core, CVSS 9.2. Details leaked on the 20th, before the embargo ended.
- The vector hasn't been confirmed. Public analysis points to session upload progress handling in multipart POSTs, with no auth needed. Some researchers say there's a second path through the multipart parser, which would explain why the ini change isn't enough.
- Cloudflare and Patchstack report attacks since the morning of the 21st.
- Expected fixed versions: 8.2.35, 8.3.36, 8.4.27 and 8.5.12. I'll update this once the advisory is out. 8.1 and older won't get a PHP patch, only distro backports.

If you can't update right away, take the service off the internet (VPN, allowlist). A WAF only helps if the origin accepts traffic from the WAF alone. And don't download or run the "PoCs" circulating on X and random sites — many carry malware.

Worth looking for signs of compromise since the 20th: php-fpm or apache spawning `sh`, `curl`, `wget` or `nc`; new `.php` files in the webroot; new cron jobs or users; `SIGSEGV` in the php-fpm log.

## Links

- https://www.php.net/
- https://sansec.io/research/php2shell
- https://www.huntress.com/blog/php2shell-leaked-critical-php-vulnerabilities
- https://patchstack.com/articles/php-major-vulnerability-alert-10-2026/
- https://www.tenable.com/blog/php2shell-cve-2026-109618-cve-2026-109619-frequently-asked-questions-about-critical-php-remote
