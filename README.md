# php2shell

CVE-2026-109618 and CVE-2026-109619

A script to check whether a server's PHP is exposed to PHP2Shell and to apply the temporary mitigation (turning off `session.upload_progress`) until the patch is out.

This does not fix the bug. One of the PHP 8.6 release managers already said on r/PHP that the ini change alone won't protect you and that you need to update PHP:

<img src="img/release-manager-reddit.png" alt="PHP 8.6 release manager on r/PHP: INI files alone won't protect you. You need to update PHP." width="600" />

Thread: https://www.reddit.com/r/PHP/comments/1xb2utu/upcoming_critical_php_security_release/

So the ini change is only there to shrink the attack surface until the patch lands. After that, use the script to confirm the server was actually updated.

The patch is due today, October 21, at 14:00 UTC:

<img width="1329" height="597" alt="image" src="https://github.com/user-attachments/assets/2e7b2b83-9bbb-4515-a393-32abe2322c72" />

<details>
<summary>Announcement text</summary>

> Upcoming Critical PHP Security Release
>
> The PHP security team would like to give advance notice of an upcoming security release.
>
> It is scheduled for Wednesday, 21 October 2026 at 14:00 UTC.
>
> It addresses two critical vulnerabilities, both rated CVSS v4.0 9.2.
>
> All PHP users are encouraged to prepare now so they can upgrade as soon as the release is available.
>
> We reserve the right to release earlier should details of either vulnerability become public, or should evidence of active exploitation appear in the wild.
>
> Full details, affected versions, and the fixed versions will be published with the release.
>
> Thank you for helping us keep PHP secure.

</details>

Source: https://news-web.php.net/php.announce/509

## Usage

```sh
curl -fsSLO https://raw.githubusercontent.com/5kr1pt/fix-to-php2shell/main/php2shell.sh
sh php2shell.sh check
sudo sh php2shell.sh fix
```

Once the patch is out, update PHP (`check` prints the right command for your distro) and run `check` again. It should end with `RESULTADO: CORRIGIDO`.

The script output is in Portuguese. The last line is always `RESULTADO: ...`, with one of these values:

- `CORRIGIDO`: patched;
- `VULNERAVEL_SEM_EXPOSICAO`: vulnerable, but stopped or only reachable from localhost;
- `VULNERAVEL_MITIGADO`: vulnerable and reachable over the network, mitigation applied;
- `VULNERAVEL_EXPOSTO`: vulnerable, reachable over the network, no mitigation;
- `SEM_PHP_WEB`: no PHP serving web traffic.

Commands:

- `check`: lists every PHP that serves web traffic (php-fpm, mod_php, `php -S`), with its version, whether it's patched, whether the mitigation is active, and whether it's running and listening on the network. Changes nothing.
- `fix`: writes `zz-php2shell.ini` to every PHP `conf.d`, tests the config and reloads php-fpm and Apache.
- `undo`: removes what `fix` created and reloads.
- `docker check|fix|undo [container...]`: runs inside containers (docker or podman). With no names it goes through every running container that has PHP.

Exit codes, from lowest to highest risk:

- 0: patched;
- 1: vulnerable, but stopped or localhost only;
- 2: vulnerable, mitigated;
- 3: vulnerable and exposed;
- 4: error.

Since the ini change isn't a fix, a stopped service or one that only listens on localhost counts as lower risk than a mitigated one.

The network check only sees the host itself. If you removed external access at the proxy, firewall or DNS, the script can't tell. The internal network can still reach the service, so it stays `EXPOSTO`. That's on purpose.

Works on Debian/Ubuntu, RHEL/Rocky/Alma, Alpine, the official `php:*` images, Remi, cPanel, Plesk and CloudLinux.

On Ubuntu the version doesn't change with the patch (it stays `8.3.6`), so the script looks for the CVE IDs in the package changelog. It also warns when:

- a pool forces `upload_progress = On`;
- the process is still running the old binary after an upgrade;
- the service is stopped but enabled at boot;
- php-fpm accepts FastCGI straight from the network (e.g. `0.0.0.0:9000`);
- the version is 8.1 or older, which won't get a PHP patch.

## Docker and Kubernetes

`docker fix` is gone as soon as the container is recreated. To make it stick, add this to the Dockerfile:

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

## Tests

Tested on:

- Laravel 13 (`php:8.4-fpm` + nginx)
- WordPress (`wordpress:php8.3-apache`)
- Debian 13 with php-fpm
- Ubuntu 24.04 with Apache + mod_php
- Rocky 9 with httpd + php-fpm
- Alpine (`php:8.3-fpm-alpine`)
- Debian with systemd

On all of them the feature was on before and turned off after `fix`. The app and file uploads kept working, and `undo` turned the feature back on.

The network check was tested with nginx on `0.0.0.0` and on `127.0.0.1`, php-fpm stopped (enabled and disabled at boot) and php-fpm listening on `0.0.0.0:9000`.

The test doesn't trust `ini_get()`. It sends a multipart POST with `PHP_SESSION_UPLOAD_PROGRESS` and checks whether PHP wrote the session file to disk. That happens before any application code runs, even on Laravel, which doesn't use native PHP sessions at all.

This shows the mitigation was applied, not that it stops the exploit. There's no reliable public PoC yet.

```sh
tests/lab.sh up && tests/lab.sh test && tests/lab.sh down
```

## What we know so far

- Two RCEs in PHP core, CVSS 9.2. Details leaked on the 20th, before the embargo ended.
- The vector hasn't been confirmed. Public analysis points to session upload progress handling in multipart POSTs, with no auth needed. Some researchers say there's a second path through the multipart parser, which would explain why the ini change isn't enough.
- Cloudflare and Patchstack report attacks since the morning of the 21st.
- Expected fixed versions: 8.2.35, 8.3.36, 8.4.27 and 8.5.12. I'll update this once the advisory is out. 8.1 and older won't get a PHP patch, only distro backports.

If you can't update right away, take the service off the internet (VPN, allowlist). A WAF only helps if the origin accepts traffic from the WAF alone.

Worth looking for signs of compromise since the 20th:

- php-fpm or apache spawning `sh`, `curl`, `wget` or `nc`;
- new `.php` files in the webroot;
- new cron jobs or users;
- `SIGSEGV` in the php-fpm log.

## Links

- https://www.php.net/
- https://sansec.io/research/php2shell
- https://www.huntress.com/blog/php2shell-leaked-critical-php-vulnerabilities
- https://patchstack.com/articles/php-major-vulnerability-alert-10-2026/
- https://www.tenable.com/blog/php2shell-cve-2026-109618-cve-2026-109619-frequently-asked-questions-about-critical-php-remote
