# php2shell

CVE-2026-109618 and CVE-2026-109619

Script pra checar se o PHP de um servidor está exposto ao PHP2Shell e aplicar a mitigação temporária (desligar `session.upload_progress`) até o patch sair.

Isso não corrige a falha. Um dos release managers do PHP 8.6 já avisou no r/PHP que só o ini não protege e que tem que atualizar o PHP:

<img src="img/release-manager-reddit.png" alt="Release manager do PHP 8.6 no r/PHP: INI files alone won't protect you. You need to update PHP." width="600" />

Thread: https://www.reddit.com/r/PHP/comments/1xb2utu/upcoming_critical_php_security_release/

Então o ini serve pra reduzir a superfície enquanto o patch não sai. Depois o script serve pra confirmar que o servidor foi atualizado.

O patch sai hoje, 21/10, às 14:00 UTC (11:00 de Brasília):

<img width="1329" height="597" alt="image" src="https://github.com/user-attachments/assets/2e7b2b83-9bbb-4515-a393-32abe2322c72" />

<details>
<summary>Texto do aviso</summary>

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

Fonte: https://news-web.php.net/php.announce/509

## Como usar

```sh
curl -fsSLO https://raw.githubusercontent.com/5kr1pt/fix-to-php2shell/main/php2shell.sh
sh php2shell.sh check
sudo sh php2shell.sh fix
```

Quando o patch sair, atualize o PHP (o `check` mostra o comando certo pra sua distro) e rode o `check` de novo. Tem que aparecer `RESULTADO: CORRIGIDO`.

Comandos:

- `check`: lista cada PHP que atende web (php-fpm, mod_php, `php -S`), com versão, se já tem o patch e se a mitigação está ativa. Não altera nada.
- `fix`: cria `zz-php2shell.ini` nos `conf.d` do PHP, testa a config e recarrega o php-fpm e o Apache.
- `undo`: remove o que o `fix` criou e recarrega.
- `docker check|fix|undo [container...]`: roda dentro dos containers (docker ou podman). Sem nome, passa por todos que têm PHP.

Exit code: 0 corrigido, 1 vulnerável mas mitigado, 2 vulnerável sem mitigação, 3 erro.

Funciona em Debian/Ubuntu, RHEL/Rocky/Alma, Alpine, imagens oficiais `php:*`, Remi, cPanel, Plesk e CloudLinux.

No Ubuntu a versão não muda com o patch (continua `8.3.6`), então o script procura os CVEs no changelog do pacote. Ele também avisa quando:

- algum pool força `upload_progress = On`;
- o processo continua rodando o binário antigo depois do upgrade;
- a versão é 8.1 ou anterior, que não vai ter patch do PHP.

## Docker e Kubernetes

O `docker fix` some quando o container é recriado. Pra valer, coloque no Dockerfile:

```dockerfile
RUN echo 'session.upload_progress.enabled = 0' > "$PHP_INI_DIR/conf.d/zz-php2shell.ini"
```

No Kubernetes dá pra montar via ConfigMap sem rebuild:

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
# no container PHP do Deployment
volumeMounts:
  - name: php2shell
    mountPath: /usr/local/etc/php/conf.d/zz-php2shell.ini
    subPath: zz-php2shell.ini
volumes:
  - name: php2shell
    configMap:
      name: php2shell-mitigation
```

Depois rode `kubectl rollout restart deploy/<app>`. Pro patch, atualize a imagem base e faça o build de novo.

## Testes

Ambientes testados:

- Laravel 13 (`php:8.4-fpm` + nginx)
- WordPress (`wordpress:php8.3-apache`)
- Debian 13 com php-fpm
- Ubuntu 24.04 com Apache + mod_php
- Rocky 9 com httpd + php-fpm
- Alpine (`php:8.3-fpm-alpine`)
- Debian com systemd

Em todos, o recurso estava ativo antes e desligou com o `fix`. A aplicação e o upload continuaram funcionando, e o `undo` religou o recurso.

O teste não confia no `ini_get()`. Ele manda um POST multipart com `PHP_SESSION_UPLOAD_PROGRESS` e confere se o PHP gravou o arquivo de sessão no disco. Isso acontece antes do código da aplicação, até no Laravel, que nem usa a sessão nativa do PHP.

Isso mostra que a mitigação foi aplicada, não que ela segura o exploit. Ainda não tem PoC confiável publicado.

```sh
tests/lab.sh up && tests/lab.sh test && tests/lab.sh down
```

## O que se sabe até agora

- São duas RCEs no core do PHP, CVSS 9.2. Os detalhes vazaram no dia 20, antes do embargo.
- O vetor não foi confirmado. A análise pública aponta pro upload progress da sessão em POST multipart, sem autenticação. Tem gente dizendo que existe outro caminho pelo parser de multipart, o que bate com o ini não ser suficiente.
- Cloudflare e Patchstack relatam ataques desde a manhã do dia 21.
- Versões corrigidas esperadas: 8.2.35, 8.3.36, 8.4.27 e 8.5.12. Atualizo aqui quando sair o advisory. Da 8.1 pra baixo não vai ter patch do PHP, só backport da distro.

Se não der pra atualizar logo, tire o serviço da internet (VPN, allowlist). WAF só ajuda se a origem aceitar tráfego só dele.

Vale procurar sinais de comprometimento desde o dia 20:

- php-fpm ou apache abrindo `sh`, `curl`, `wget` ou `nc`;
- `.php` novo no webroot;
- cron ou usuário novo;
- `SIGSEGV` no log do php-fpm.

## Links

- https://www.php.net/
- https://sansec.io/research/php2shell
- https://www.huntress.com/blog/php2shell-leaked-critical-php-vulnerabilities
- https://patchstack.com/articles/php-major-vulnerability-alert-10-2026/
- https://www.tenable.com/blog/php2shell-cve-2026-109618-cve-2026-109619-frequently-asked-questions-about-critical-php-remote
