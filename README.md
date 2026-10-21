# php2shell

CVE-2026-109618 and CVE-2026-109619

Checagem e mitigação temporária do **PHP2Shell** (CVE-2026-109618 / CVE-2026-109619), duas falhas críticas de execução remota de código no núcleo do PHP.

> **A mitigação é parcial.** Ela reduz a exposição enquanto o patch não chega, mas não fecha a falha. O time do PHP afirma que só a atualização corrige. Use o script para ganhar tempo e **atualize o PHP assim que o release sair**.

## Aviso oficial do PHP (20/10/2026)

<img width="1329" height="597" alt="image" src="https://github.com/user-attachments/assets/2e7b2b83-9bbb-4515-a393-32abe2322c72" />

<details>
<summary>Texto do aviso</summary>

> **Upcoming Critical PHP Security Release**
>
> The PHP security team would like to give advance notice of an **upcoming security release**.
>
> **It is scheduled for Wednesday, 21 October 2026 at 14:00 UTC.**
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

Fonte: [php.net](https://www.php.net/) · [php.announce](https://news-web.php.net/php.announce/509)

**14:00 UTC = 11:00 em Brasília.**

## Uso rápido

```sh
curl -fsSLO https://raw.githubusercontent.com/5kr1pt/fix-to-php2shell/main/php2shell.sh
sh php2shell.sh check          # está vulnerável? está mitigado? (não altera nada)
sudo sh php2shell.sh fix       # aplica a mitigação e recarrega PHP-FPM / Apache
```

Quando o patch sair:

```sh
sudo apt-get update && sudo apt-get install --only-upgrade 'php*'   # ou: sudo dnf upgrade 'php*'
sh php2shell.sh check          # tem que dar RESULTADO: CORRIGIDO
```

O `check` já imprime o comando exato de atualização para a máquina em que roda.

## Comandos

| Comando | O que faz |
|---|---|
| `check` | Lista cada PHP que atende web (PHP-FPM, mod_php, `php -S`), a versão, se o patch está aplicado e se a mitigação está ativa. Não altera nada. |
| `fix` | Cria `zz-php2shell.ini` com `session.upload_progress.enabled = 0` em todos os `conf.d` do PHP. Valida a config e recarrega o PHP-FPM e o Apache com mod_php (`systemctl reload` ou reload gracioso). Termina rodando o `check`. |
| `undo` | Remove os arquivos criados pelo `fix` e recarrega. |
| `docker check\|fix\|undo [container...]` | Roda o comando dentro dos containers em execução (docker ou podman). Sem nomes, varre todos os que têm PHP. |

Código de saída, útil em Ansible/CI: `0` corrigido · `1` vulnerável com mitigação · `2` vulnerável **sem** mitigação · `3` erro. A última linha é sempre `RESULTADO: ...`.

## O que o script cobre

- **Debian/Ubuntu:** `/etc/php/X.Y/{fpm,apache2,cli}`, inclusive várias versões lado a lado.
- **RHEL/Rocky/Alma:** `/etc/php.ini` e `/etc/php.d`, com módulos do AppStream.
- **Alpine:** `/etc/phpXY`.
- **Imagens oficiais `php:*-fpm` e `php:*-apache`:** `/usr/local/etc/php/conf.d`.
- **Painéis e repositórios alternativos:** Remi (SCL), cPanel EA-PHP, Plesk e CloudLinux alt-php.
- **Backport de distro:** o Ubuntu 24.04 continua mostrando `PHP 8.3.6` mesmo corrigido. Por isso o script procura os CVEs no changelog do pacote (dpkg/rpm), em vez de olhar só o número da versão.
- **Pool ou vhost que religa o recurso** (`php_admin_flag[session.upload_progress.enabled] = on`): o script avisa e aponta o arquivo.
- **Processo rodando o binário antigo** depois do `apt upgrade` sem reiniciar: o script avisa.
- **PHP 8.1 ou anterior:** o script avisa que o PHP não vai publicar correção para essas versões.

## Containers

Alterar um container em execução **não sobrevive** a um recreate. O `docker fix` serve como emergência. Para valer:

**Dockerfile** (o `check` imprime o caminho certo para a imagem):

```dockerfile
RUN echo 'session.upload_progress.enabled = 0' > "$PHP_INI_DIR/conf.d/zz-php2shell.ini"
```

**Kubernetes** (sem rebuild):

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: php2shell-mitigation
data:
  zz-php2shell.ini: |
    session.upload_progress.enabled = 0
---
# no container PHP do Deployment:
#   volumeMounts:
#     - name: php2shell
#       mountPath: /usr/local/etc/php/conf.d/zz-php2shell.ini
#       subPath: zz-php2shell.ini
#   volumes:
#     - name: php2shell
#       configMap:
#         name: php2shell-mitigation
```

Depois rode `kubectl rollout restart deploy/<app>`. Para o patch, atualize a imagem base (`docker pull php:8.x-fpm`), refaça o build e o deploy.

## Testes

Validado em laboratório Docker, em stacks reais. O teste não lê só o `ini_get()`: ele confirma o comportamento em runtime. Manda um POST multipart com `PHP_SESSION_UPLOAD_PROGRESS` e confere se o PHP grava o arquivo de sessão no disco. Isso acontece **antes do código da aplicação**, inclusive no Laravel, que nem usa a sessão nativa do PHP.

| Ambiente | Stack | probe antes | fix | probe depois | upload/app | undo |
|---|---|---|---|---|---|---|
| Laravel 13 | `php:8.4-fpm` + nginx | ativo | ok | **desligado** | ok | ok |
| WordPress | `wordpress:php8.3-apache` (mod_php) + MariaDB | ativo | ok | **desligado** | ok | ok |
| Debian 13 | php8.4-fpm (apt) + nginx | ativo | ok | **desligado** | ok | ok |
| Ubuntu 24.04 | Apache + mod_php 8.3 + php-fpm (apt) | ativo | ok | **desligado** | ok | ok |
| Rocky 9 | httpd + php-fpm 8.2 (AppStream) | ativo | ok | **desligado** | ok | ok |
| Alpine | `php:8.3-fpm-alpine` + nginx (busybox) | ativo | ok | **desligado** | ok | ok |
| Debian 13 + systemd | php8.4-fpm como serviço (`systemctl reload`) + nginx | ativo | ok | **desligado** | ok | ok |

Também foram testados: pool forçando `On`, backport detectado pelo changelog, binário trocado em disco sem restart e FPM daemonizado (`-D`, o PID muda no reload).

Para rodar de novo, por exemplo depois do patch:

```sh
tests/lab.sh up && tests/lab.sh test && tests/lab.sh down
```

## O que se sabe (21/10/2026, manhã)

- São duas falhas de RCE no núcleo do PHP, CVSS v4 9.2. Os detalhes vazaram em 20/10, antes do embargo.
- **Vetor não confirmado oficialmente.** A análise pública aponta o tratamento de `session.upload_progress` em POST `multipart/form-data`, alcançável sem autenticação e antes do código da aplicação. Há pesquisadores que dizem existir um segundo caminho pelo parser de multipart, por isso a mitigação é parcial.
- **Exploração:** a Cloudflare e parceiros de hospedagem da Patchstack relatam ataques desde a manhã de 21/10. watchTowr e Huntress ainda não confirmavam.
- **Versões corrigidas esperadas** (sem confirmação oficial): 8.2.35, 8.3.36, 8.4.27 e 8.5.12. A **8.1 e anteriores estão em fim de vida** e não terão correção do PHP. Só backport de distro ou repositório.
- O script usa essas versões esperadas. Assim que o advisory sair, elas serão atualizadas aqui. Para sobrescrever sem esperar: `PHP2SHELL_FIXED="8.2.35 8.3.36 8.4.27 8.5.12" sh php2shell.sh check`.

## Além do PHP

- Se não der para atualizar logo, **tire da internet**: VPN, allowlist ou página de manutenção estática (recomendação do CERT-EU e do NCSC).
- **WAF** (por exemplo, as regras emergenciais da Cloudflare) só adianta se a origem aceitar conexões **apenas** do WAF.
- Bloquear `multipart/form-data` no nginx/Apache nas rotas que não recebem upload reduz bastante a superfície, mas quebra upload. Teste antes.
- **Procure sinais de comprometimento desde 20/10:**
  - php-fpm, apache2 ou httpd abrindo `sh`, `bash`, `curl`, `wget`, `nc` ou `python`;
  - arquivos `.php` novos no webroot;
  - cron e usuários novos;
  - `SIGSEGV` no log do php-fpm.

## Referências

- [php.net](https://www.php.net/) · [php.announce](https://news-web.php.net/php.announce/509)
- [Sansec](https://sansec.io/research/php2shell)
- [Huntress](https://www.huntress.com/blog/php2shell-leaked-critical-php-vulnerabilities)
- [Patchstack](https://patchstack.com/articles/php-major-vulnerability-alert-10-2026/)
- [Tenable FAQ](https://www.tenable.com/blog/php2shell-cve-2026-109618-cve-2026-109619-frequently-asked-questions-about-critical-php-remote)
- [The Hacker News: o que protege e o que não protege](https://thehackernews.com/2026/10/php2shell-what-actually-protects-you.html)
