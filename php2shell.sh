#!/bin/sh
# php2shell.sh - checagem e mitigação temporária do PHP2Shell (CVE-2026-109618 / CVE-2026-109619)
#
#        ./php2shell.sh check                    diz se o PHP desta máquina está vulnerável e/ou mitigado (não altera nada)
#   sudo ./php2shell.sh fix                      desliga session.upload_progress e recarrega PHP-FPM / Apache
#   sudo ./php2shell.sh undo                     desfaz o fix
#   sudo ./php2shell.sh block                    (opção) bloqueia POST multipart no Apache/nginx (corta mais, mas quebra upload)
#   sudo ./php2shell.sh unblock                  desfaz o block
#   sudo ./php2shell.sh docker check|fix|undo|block|unblock [container...]
#                                                roda o comando dentro dos containers em execução (docker/podman)
#
# PHP2SHELL_UPLOAD_PATHS="/upload /wp-admin"     no block, caminhos que continuam aceitando upload (allowlist)
#
# Código de saída: 0 = corrigido | 1 = vulnerável, mas parado ou sem exposição em rede
#                  2 = vulnerável com mitigação | 3 = vulnerável e exposto | 4 = erro
#
# A mitigação é PARCIAL: reduz a exposição, não fecha a falha. Só o patch do PHP resolve.
# POSIX sh de propósito: roda em Debian/Ubuntu, RHEL/Rocky, Alpine e nas imagens oficiais do Docker.

set -u

SCRIPT_VERSION=2026.10.21-2
CVES="CVE-2026-109618 CVE-2026-109619"
# Versões com a correção, por branch. Até o advisory oficial (21/10/2026 14:00 UTC) são as ESPERADAS.
# Para sobrescrever sem editar o script: PHP2SHELL_FIXED="8.2.35 8.3.36 8.4.27 8.5.12" ./php2shell.sh check
FIXED=${PHP2SHELL_FIXED:-"8.2.35 8.3.36 8.4.27 8.5.12"}
FIXED_CONFIRMED=0
RELEASE_UTC=202610211400
INI_NAME=zz-php2shell.ini
BLOCK_NAME=php2shell-block.conf
TAG=php2shell.sh

if [ -t 1 ]; then
	R=$(printf '\033[31m'); G=$(printf '\033[32m'); Y=$(printf '\033[33m'); B=$(printf '\033[1m'); N=$(printf '\033[0m')
else
	R='' G='' Y='' B='' N=''
fi

ok()   { printf '  %s✔%s %s\n' "$G" "$N" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*"; }
bad()  { printf '  %s✘%s %s\n' "$R" "$N" "$*"; }
die()  { printf '%serro:%s %s\n' "$R" "$N" "$*" >&2; exit 4; }

need_root() { [ "$(id -u)" = 0 ] || die "precisa de root: sudo $0 $*"; }

in_container() {
	[ -f /.dockerenv ] || [ -f /run/.containerenv ] || [ -n "${KUBERNETES_SERVICE_HOST:-}" ] ||
		grep -qE 'docker|kubepods|containerd|libpod' /proc/1/cgroup 2>/dev/null
}

# ---------- versões ----------

php_version() { "$1" -v 2>/dev/null | sed -n '1s/^PHP \([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p'; }

ver_lt() {
	awk -v a="$1" -v b="$2" 'BEGIN { split(a, x, "."); split(b, y, ".")
		for (i = 1; i <= 3; i++) { if (x[i] + 0 < y[i] + 0) exit 0; if (x[i] + 0 > y[i] + 0) exit 1 }
		exit 1 }'
}

fixed_for() {
	local f
	for f in $FIXED; do [ "${f%.*}" = "${1%.*}" ] && { echo "$f"; return; }; done
}

# changelog do pacote da distro (backport não muda a versão: Ubuntu 24.04 segue "8.3.6" mesmo corrigido)
pkg_changelog() {
	local f pkg
	if command -v rpm >/dev/null 2>&1 && pkg=$(rpm -qf "$1" 2>/dev/null); then
		rpm -q --changelog "$pkg" 2>/dev/null; return
	fi
	for f in /usr/share/doc/php"$2"*/changelog.Debian.gz; do [ -f "$f" ] && zcat "$f" 2>/dev/null; done
}

has_backport() {
	local log c
	log=$(pkg_changelog "$1" "$2")
	for c in $CVES; do printf '%s' "$log" | grep -q "$c" || return 1; done
}

distro_owned() {
	dpkg -S "$1" >/dev/null 2>&1 || rpm -qf "$1" >/dev/null 2>&1 || apk info -q --who-owns "$1" >/dev/null 2>&1
}

# imprime a linha de patch; retorna 0 = corrigido, 1 = vulnerável
patch_status() {
	local v="$2" br fx note=""
	[ "$FIXED_CONFIRMED" = 1 ] || note=" (versão esperada, confirmar no advisory)"
	[ -n "$v" ] || { warn "patch: não consegui identificar a versão"; return 1; }
	br=${v%.*}
	if has_backport "$1" "$br"; then
		ok "patch: corrigido (o changelog do pacote cita $CVES)"; return 0
	fi
	fx=$(fixed_for "$v")
	if [ -z "$fx" ]; then
		if ver_lt "$v" 8.2.0; then
			EOL_SEEN=1
			if distro_owned "$1"; then
				bad "patch: PHP $br está em fim de vida, o PHP não vai corrigir. Só a distro/repositório pode publicar backport: acompanhe o aviso de segurança dela"
			else
				bad "patch: PHP $br está em fim de vida, NÃO vai ter correção oficial. Migre para 8.2+ ou tire da internet"
			fi
		else
			bad "patch: vulnerável (não há versão corrigida conhecida para $br)"
		fi
		return 1
	fi
	if ver_lt "$v" "$fx"; then bad "patch: vulnerável, corrigido em $fx$note"; return 1; fi
	ok "patch: corrigido ($v >= $fx)"
}

# ---------- configuração ----------

ini_from_info() { [ -x "${1:-}" ] && "$1" -i 2>/dev/null | sed -n 's/^session\.upload_progress\.enabled => \([^ ]*\) => .*/\1/p' | head -n1; }
scan_dir()      { "$1" -i 2>/dev/null | sed -n 's/^Scan this dir for additional \.ini files => //p' | head -n1 | cut -d: -f1; }
loaded_ini()    { "$1" -i 2>/dev/null | sed -n 's/^Loaded Configuration File => //p' | head -n1; }

# valor efetivo lendo php.ini + conf.d/*.ini na mesma ordem do PHP (usado para o mod_php do Debian/Ubuntu)
ini_static() {
	local v=1 f x
	for f in "$1/php.ini" "$1"/conf.d/*.ini; do
		[ -f "$f" ] || continue
		x=$(sed -n 's/^[[:space:]]*session\.upload_progress\.enabled[[:space:]]*=[[:space:]]*\([^[:space:];]*\).*/\1/p' "$f" | tail -n1)
		[ -n "$x" ] && v=$x
	done
	case $(printf '%s' "$v" | tr -d "\"'" | tr '[:upper:]' '[:lower:]') in 0|off|false|no|none|'') echo Off ;; *) echo On ;; esac
}

fpm_dump() { if [ -n "$2" ]; then "$1" -tt -y "$2" 2>&1; else "$1" -tt 2>&1; fi; }

# OFF | ON | ON:pool1,pool2 - considera php_value/php_admin_value de cada pool por cima do php.ini
fpm_effective() {
	fpm_dump "$1" "$2" | awk -v ini="$3" '
		/NOTICE: \[/ { p = $0; sub(/.*\[/, "", p); sub(/\].*/, "", p); if (p != "global") pools[++n] = p; next }
		/php_(admin_)?value\[session\.upload_progress\.enabled\]/ {
			a = ($0 ~ /php_admin_value/); if (a || !(p in adm)) { ov[p] = tolower($NF); if (a) adm[p] = 1 } }
		function on(v) { v = tolower(v); return !(v == "0" || v == "off" || v == "false" || v == "no" || v == "") }
		END {
			if (n == 0) { print (on(ini) ? "ON" : "OFF"); exit }
			for (i = 1; i <= n; i++) { p = pools[i]; v = (p in ov) ? ov[p] : ini; if (on(v)) l = l (l ? "," : "") p }
			print (l == "" ? "OFF" : "ON:" l) }'
}

# imprime a linha de mitigação; retorna 0 = aplicada, 1 = não aplicada
mitig_status() {
	case $1 in
	Off | OFF) ok "mitigação: aplicada (session.upload_progress = Off)" ;;
	On | ON)   bad "mitigação: não aplicada (session.upload_progress = On)"; return 1 ;;
	ON:*)      bad "mitigação: não aplicada no(s) pool(s) ${1#ON:} (session.upload_progress = On)"; return 1 ;;
	'')        ok "mitigação: n/a (extensão session não carregada)" ;;
	*)         warn "mitigação: não consegui verificar"; return 1 ;;
	esac
}

# ---------- descoberta ----------

# pid|exe|comm|cmdline dos processos de PHP e Apache (via /proc: as imagens oficiais não têm ps)
procs() {
	local d comm cmd exe
	for d in /proc/[0-9]*; do
		read -r comm 2>/dev/null < "$d/comm" || continue
		case $comm in php* | apache2 | httpd | frankenphp | lsphp*) ;; *) continue ;; esac
		cmd=$(tr '\0' ' ' 2>/dev/null < "$d/cmdline")
		exe=$(readlink "$d/exe" 2>/dev/null)
		printf '%s|%s|%s|%s\n' "${d#/proc/}" "$exe" "$comm" "$cmd"
	done
}

# pid|exe|conf dos masters do PHP-FPM ("#deleted" = binário trocado em disco e ainda não reiniciado)
fpm_masters() {
	procs | while IFS='|' read -r pid exe comm cmd; do
		case $comm in php-fpm*) ;; *) continue ;; esac
		case $cmd in *"master process"*) ;; *) continue ;; esac
		conf=$(printf '%s' "$cmd" | sed -n 's/.*master process (\(.*\)).*/\1/p')
		[ -n "$exe" ] || exe=$(command -v "$comm" 2>/dev/null || echo "/usr/sbin/$comm")
		printf '%s|%s|%s\n' "$pid" "$(printf '%s' "$exe" | sed 's/ (deleted)$/#deleted/')" "$conf"
	done
}

# pid|libphp dos processos-pai do Apache que carregaram o mod_php
apache_modphp() {
	procs | while IFS='|' read -r pid exe comm cmd; do
		case $comm in apache2 | httpd) ;; *) continue ;; esac
		ppid=$(sed 's/.*) //' "/proc/$pid/stat" 2>/dev/null | cut -d' ' -f2)
		pcomm=; read -r pcomm 2>/dev/null < "/proc/$ppid/comm"
		[ "$pcomm" = "$comm" ] && continue
		lib=$(awk '/libphp|mod_php/ { print $6 ($7 == "(deleted)" ? "#deleted" : ""); exit }' "/proc/$pid/maps" 2>/dev/null)
		[ -n "$lib" ] && printf '%s|%s\n' "$pid" "$lib"
	done
}

apache_running() { procs | grep -qE '^[0-9]+\|[^|]*\|(apache2|httpd)\|'; }

list_bins() {
	local b
	for b in /usr/bin/php /usr/bin/php[0-9]* /usr/local/bin/php /usr/sbin/php-fpm* /usr/local/sbin/php-fpm \
		/opt/remi/php*/root/usr/bin/php /opt/remi/php*/root/usr/sbin/php-fpm \
		/opt/cpanel/ea-php*/root/usr/bin/php /opt/cpanel/ea-php*/root/usr/sbin/php-fpm \
		/opt/plesk/php/*/bin/php /opt/plesk/php/*/sbin/php-fpm \
		/opt/alt/php*/usr/bin/php /opt/alt/php*/usr/sbin/php-fpm; do
		[ -f "$b" ] && [ -x "$b" ] && readlink -f "$b"
	done | grep -E '/php(-fpm)?[0-9.]*$' | sort -u
}

modphp_libs() {
	local f
	for f in /usr/lib/apache2/modules/libphp*.so /usr/lib64/httpd/modules/libphp*.so /usr/lib/httpd/modules/libphp*.so \
		/usr/local/apache2/modules/libphp*.so /usr/lib/apache2/mod_php*.so; do
		[ -f "$f" ] && readlink -f "$f"
	done | sort -u
}

lib_xy() { # libphp8.3.so -> 8.3 | mod_php83.so -> 8.3 | libphp.so -> vazio
	local n="${1##*/}" d
	case $n in
	libphp[0-9].[0-9].so) d=${n#libphp}; echo "${d%.so}" ;;
	mod_php[0-9][0-9].so) d=${n#mod_php}; d=${d%.so}; echo "${d%?}.${d#?}" ;;
	esac
}

cli_bin() { # CLI correspondente a um X.Y (ou a padrão)
	local c
	for c in ${1:+/usr/bin/php$1 /usr/bin/php$(echo "$1" | tr -d .)} /usr/local/bin/php /usr/bin/php; do
		[ -x "$c" ] && { echo "$c"; return; }
	done
}

service_unit() { sed -n 's#.*/\([^/]*\.service\)$#\1#p' "/proc/$1/cgroup" 2>/dev/null | head -n1; }

ini_dirs() {
	local b sd d
	{
		for b in $(list_bins); do
			sd=$(scan_dir "$b")
			[ -n "$sd" ] && [ "$sd" != "(none)" ] && echo "$sd"
		done
		for d in /etc/php/*/*/conf.d; do [ -d "$d" ] && echo "$d"; done
	} | sort -u
}

# ---------- exposição ----------

# endereço|processos de cada porta TCP em LISTEN (ss, ou netstat no busybox)
listeners() {
	if command -v ss >/dev/null 2>&1; then
		ss -ltnp 2>/dev/null | awk '$1 == "LISTEN" { names = ""; s = $0
			while (match(s, /\("[^"]+"/)) { n = substr(s, RSTART + 2, RLENGTH - 3); s = substr(s, RSTART + RLENGTH)
				if (index("," names ",", "," n ",") == 0) names = names (names ? "," : "") n }
			print $4 "|" names }'
	elif command -v netstat >/dev/null 2>&1; then
		netstat -ltnp 2>/dev/null | awk '$6 == "LISTEN" { split($7, a, "/"); sub(/:.*/, "", a[2]); print $4 "|" a[2] }'
	else
		return 1
	fi
}

# processos que recebem HTTP (ou FastCGI) e podem levar a requisição até o PHP
WEB_PROCS='nginx|apache2|httpd|haproxy|caddy|lighttpd|traefik|envoy|varnishd|lshttpd|litespeed|openlitespeed|frankenphp|php[^,]*|hitch|docker-proxy|rootlessport'

# EXPO = container | ? (não verificado) | local | "0.0.0.0:80 (nginx), ..."
# Na dúvida fica como exposto: dizer "não exposto" sem ter certeza é o erro perigoso.
host_exposure() {
	local l
	if in_container; then EXPO=container; return; fi
	if [ "$(id -u)" != 0 ] || ! l=$(listeners); then EXPO='?'; return; fi
	# portas sem nenhum dono visível = ss sem permissão para ver os processos
	if [ -n "$l" ] && ! printf '%s\n' "$l" | grep -q '|.'; then EXPO='?'; return; fi
	EXPO=$(printf '%s\n' "$l" | awk -F'|' -v re="(^|,)($WEB_PROCS)(,|\$)" '
		$1 !~ /^(127\.|\[::1\]|\[::ffff:127\.|::1:|localhost)/ && $2 ~ re { printf "%s%s (%s)", (n++ ? ", " : ""), $1, $2 }')
	[ -n "$EXPO" ] || EXPO=local
}

boot_units() { # units habilitadas no boot que casam com o padrão (só fora de container)
	in_container && return 0
	command -v systemctl >/dev/null 2>&1 || return 0
	systemctl list-unit-files --type=service --no-legend 2>/dev/null |
		awk -v re="$1" '$1 ~ re && $2 == "enabled" { printf "%s%s", (n++ ? " " : ""), $1 }'
}

# imprime a linha de exposição; retorna 0 = sem exposição em rede (verificado), 1 = exposto ou não verificado
expo_status() {
	case $EXPO in
	local)     ok "exposição: só localhost/socket nesta máquina (nenhum servidor web escutando na rede)" ;;
	container) warn "exposição: container, depende das portas publicadas/ingress (não dá para ver daqui)"; return 1 ;;
	'?')       warn "exposição: não consegui verificar (rode com sudo; precisa de ss ou netstat)"; return 1 ;;
	*)         bad "exposição: escuta na rede em $EXPO"; return 1 ;;
	esac
}

# ---------- check ----------

acc() { FOUND=$((FOUND + 1)); [ "$1" -gt "$WORST" ] && WORST=$1; return 0; }

report() { # rótulo arquivo versão estado-mitigação binário-antigo(0/1) rodando(0/1) units-no-boot
	local p m e=1
	printf '\n%s%s%s\n' "$B" "$1" "$N"
	patch_status "$2" "$3"; p=$?
	if [ "$5" = 1 ]; then
		bad "o processo ainda roda o binário ANTIGO (atualizado em disco sem reiniciar): reinicie o serviço"; p=1
	fi
	mitig_status "$4"; m=$?
	if [ "$6" = 1 ]; then
		expo_status && e=0
	else
		ok "exposição: parado, não atende requisições agora"; e=0
		[ -n "${7:-}" ] && warn "habilitado no boot ($7): se o serviço subir, volta a ficar exposto"
	fi
	[ $p = 0 ] && return 0
	[ $e = 0 ] && return 1
	[ $m = 0 ] && return 2
	return 3
}

report_fpm() { # binário conf pid binário-antigo
	local v ini eff st run=0 boot=""
	v=$(php_version "$1"); ini=$(ini_from_info "$1"); eff=$(fpm_effective "$1" "$2" "$ini")
	if [ -n "$3" ]; then st="rodando, pid $3"; run=1; else st="parado"; boot=$(boot_units 'php.*fpm'); fi
	report "php-fpm $v · $1 · $st" "$1" "$v" "$eff" "$4" "$run" "$boot"
}

report_modphp() { # libphp pid binário-antigo
	local xy v eff st c run=0 boot=""
	xy=$(lib_xy "$1"); c=$(cli_bin "$xy"); v=$([ -n "$c" ] && php_version "$c")
	if [ -n "$xy" ] && [ -d "/etc/php/$xy/apache2" ]; then eff=$(ini_static "/etc/php/$xy/apache2"); else eff=$(ini_from_info "$c"); fi
	[ -n "$eff" ] || [ -n "$c" ] || eff="?"
	if [ -n "$2" ]; then st="Apache rodando, pid $2"; run=1; else st="Apache parado"; boot=$(boot_units '^(apache2|httpd)[.]service$'); fi
	report "mod_php $v · $1 · $st" "$1" "$v" "$eff" "$3" "$run" "$boot"
}

do_check() {
	local m pid r exe conf del b a lib seen="" aseen="" self=php2shell.sh sd n
	WORST=0 FOUND=0 EOL_SEEN=0
	printf '%sPHP2Shell (CVE-2026-109618 / CVE-2026-109619): check%s\n' "$B" "$N"
	printf 'host %s · %s · script %s\n' "$(cat /proc/sys/kernel/hostname 2>/dev/null)" "$(date '+%Y-%m-%d %H:%M %Z')" "$SCRIPT_VERSION"
	[ "$(id -u)" = 0 ] || warn "rode com sudo para enxergar todos os processos e configs"
	host_exposure

	for m in $(fpm_masters); do
		pid=${m%%|*}; r=${m#*|}; exe=${r%%|*}; conf=${r#*|}; del=0
		case $exe in *#deleted) del=1; exe=${exe%#deleted} ;; esac
		report_fpm "$exe" "$conf" "$pid" "$del"; acc $?
		seen="$seen $exe "
	done
	for b in $(list_bins); do
		case ${b##*/} in php-fpm*) ;; *) continue ;; esac
		case $seen in *" $b "*) continue ;; esac
		report_fpm "$b" "" "" 0; acc $?
	done

	for a in $(apache_modphp); do
		pid=${a%%|*}; lib=${a#*|}; del=0
		case $lib in *#deleted) del=1; lib=${lib%#deleted} ;; esac
		report_modphp "$lib" "$pid" "$del"; acc $?
		aseen="$aseen $lib "
	done
	for lib in $(modphp_libs); do
		case $aseen in *" $lib "*) continue ;; esac
		if apache_running && [ "$(id -u)" = 0 ]; then
			printf '\n%smod_php · %s%s\n' "$B" "$lib" "$N"
			ok "instalado, mas o Apache em execução não carrega este módulo"
			continue
		fi
		report_modphp "$lib" "" 0; acc $?
	done

	# servidor embutido (php -S, artisan serve) e SAPIs que o script não sabe ajustar
	for r in $(procs | awk -F'|' '$3 ~ /^php[0-9.]*$/ && $4 ~ / -S / { print $1 "|" $2 }
		$3 ~ /^(frankenphp|lsphp|php-cgi)/ { print $1 "|" $3 "|outro" }'); do
		pid=${r%%|*}; exe=${r#*|}
		case $r in
		*"|outro")
			printf '\n%s%s (pid %s)%s\n' "$B" "${exe%|outro}" "$pid" "$N"
			bad "SAPI que o script não ajusta sozinho: ponha 'session.upload_progress.enabled = 0' no php.ini dela, reinicie e atualize o PHP"
			acc 3 ;;
		*)
			report "php -S (servidor embutido) · $exe · pid $pid" "$exe" "$(php_version "$exe")" "$(ini_from_info "$exe")" 0 1; acc $? ;;
		esac
	done

	b=$(list_bins | grep -v '/php-fpm' | tr '\n' ' ')
	[ -n "$b" ] && printf '\n%sCLI%s (não atende requisições web, só referência): %s\n' "$B" "$N" "$b"

	printf '\n%sO que fazer agora%s\n' "$B" "$N"
	if [ "$FOUND" = 0 ]; then
		echo "  Nenhum PHP atendendo web nesta máquina."
	elif [ "$WORST" = 0 ]; then
		ok "PHP corrigido. O fix pode ficar (não atrapalha quase nenhuma aplicação) ou sair com: sudo $self undo"
	else
		n=1
		if [ "$WORST" = 1 ]; then
			echo "  Nada vulnerável atendendo na rede agora (parado ou só local). Mantenha assim até atualizar."
			echo "  Se precisar religar antes do patch, rode 'sudo $self fix' antes."
		fi
		[ "$WORST" = 3 ] && echo "  $n. Agora: sudo $self fix   (reduz o risco, NÃO corrige)" && n=$((n + 1))
		[ "$WORST" -ge 2 ] && echo "  $n. Se der, tire o serviço da internet até atualizar: o fix sozinho não protege" && n=$((n + 1))
		if [ "$(date -u +%Y%m%d%H%M)" -lt "$RELEASE_UTC" ]; then
			echo "  $n. O patch sai às 14:00 UTC (11:00 em Brasília) de 21/10. Assim que sair, atualize:"
		else
			echo "  $n. Atualize o PHP:"
		fi
		echo "       $(upgrade_hint)"
		echo "  $((n + 1)). Depois rode de novo: $self check  (tem que dar CORRIGIDO)"
		[ "$EOL_SEEN" = 1 ] && warn "PHP 8.1 ou mais antigo: o PHP não vai publicar correção. Migre para 8.2+ ou tire da internet (VPN/allowlist)."
		case $EXPO in
		container | local | '?') ;;
		*) [ "$WORST" -ge 2 ] && warn "Tirou o acesso externo no proxy/firewall/DNS? Isso não aparece daqui. A rede interna continua alcançando o serviço, então ele segue como exposto." ;;
		esac
		case $EXPO in *php-fpm*) warn "o php-fpm aceita FastCGI direto pela rede: quem alcança essa porta executa PHP, com ou sem esta falha. Deixe só em 127.0.0.1 ou socket." ;; esac
	fi
	if in_container && [ "$WORST" != 0 ]; then
		sd=$(ini_dirs | grep -v '/cli/' | head -n1)
		warn "Isto é um container: o fix some quando ele for recriado. Para valer, no Dockerfile:"
		echo "       RUN echo 'session.upload_progress.enabled = 0' > ${sd:-\$PHP_INI_DIR/conf.d}/$INI_NAME"
		echo "     e para o patch: atualize a imagem base e refaça build/deploy."
	fi

	case $WORST in
	0) [ "$FOUND" = 0 ] && r=SEM_PHP_WEB || r=CORRIGIDO ;;
	1) r=VULNERAVEL_SEM_EXPOSICAO ;;
	2) r=VULNERAVEL_MITIGADO ;;
	*) r=VULNERAVEL_EXPOSTO ;;
	esac
	printf '\nRESULTADO: %s\n' "$r"
	return "$WORST"
}

upgrade_hint() {
	local pkgs
	if in_container && [ -x /usr/local/bin/php ] && ! distro_owned /usr/local/bin/php; then
		echo "imagem oficial do PHP: atualize a imagem base e refaça o build"
	elif command -v dpkg-query >/dev/null 2>&1; then
		pkgs=$(dpkg-query -W -f='${db:Status-Abbrev}|${Package}\n' 'php*' 'libapache2-mod-php*' 2>/dev/null |
			awk -F'|' '$1 ~ /^ii/ { printf "%s ", $2 }')
		echo "sudo apt-get update && sudo apt-get install --only-upgrade $pkgs"
	elif command -v dnf >/dev/null 2>&1; then echo "sudo dnf upgrade 'php*'"
	elif command -v yum >/dev/null 2>&1; then echo "sudo yum update 'php*'"
	elif command -v apk >/dev/null 2>&1; then echo "apk update && apk upgrade"
	else echo "atualize o PHP pelo gerenciador de pacotes ou painel (cPanel/Plesk)"
	fi
}

# ---------- fix / undo ----------

write_ini() {
	cat > "$1" <<EOF
; $TAG - PHP2Shell (CVE-2026-109618 / CVE-2026-109619) - $(date '+%Y-%m-%d %H:%M %Z')
; Mitigacao PARCIAL e temporaria: NAO substitui o patch do PHP.
; Para remover: php2shell.sh undo  (ou apague este arquivo e recarregue o PHP)
session.upload_progress.enabled = 0
EOF
}

reload_all() {
	local m pid r exe conf unit ctl a i
	for m in $(fpm_masters); do
		pid=${m%%|*}; r=${m#*|}; exe=${r%%|*}; conf=${r#*|}; exe=${exe%#deleted}
		if [ -n "$conf" ]; then "$exe" -t -y "$conf" >/dev/null 2>&1; else "$exe" -t >/dev/null 2>&1; fi ||
			{ bad "php-fpm pid $pid: config inválida, NÃO recarreguei. Veja: $exe -t"; continue; }
		unit=$(service_unit "$pid")
		if [ -n "$unit" ] && command -v systemctl >/dev/null 2>&1; then
			if systemctl reload "$unit"; then ok "php-fpm recarregado ($unit)"; else bad "falhou: systemctl reload $unit"; fi
		elif kill -USR2 "$pid"; then
			# daemonizado (php-fpm -D / daemonize = yes) o master volta com outro PID: procura pela config
			i=0
			while [ $i -lt 5 ]; do sleep 1; fpm_masters | grep -q "|$conf\$" && break; i=$((i + 1)); done
			if [ $i -lt 5 ]; then ok "php-fpm recarregado (${conf:-pid $pid})"; else bad "php-fpm (${conf:-pid $pid}) não voltou depois do reload: verifique o serviço"; fi
		else
			bad "não consegui mandar reload para o php-fpm pid $pid"
		fi
	done
	for a in $(apache_modphp); do
		pid=${a%%|*}
		unit=$(service_unit "$pid")
		ctl=$(command -v apache2ctl || command -v apachectl || command -v httpd)
		if [ -n "$unit" ] && command -v systemctl >/dev/null 2>&1; then
			if systemctl reload "$unit"; then ok "Apache recarregado ($unit)"; else bad "falhou: systemctl reload $unit"; fi
		elif [ -n "$ctl" ] && "$ctl" -t >/dev/null 2>&1 && "$ctl" -k graceful 2>/dev/null; then
			ok "Apache recarregado (graceful)"
		else
			bad "não consegui recarregar o Apache (pid $pid): faça manualmente"
		fi
	done
}

do_fix() {
	local d b sd dirs
	need_root fix
	printf '%sAplicando mitigação temporária: session.upload_progress.enabled = 0%s\n' "$B" "$N"
	dirs=$(ini_dirs)
	[ -n "$dirs" ] || die "não achei nenhum diretório conf.d do PHP"
	for d in $dirs; do
		if mkdir -p "$d" && write_ini "$d/$INI_NAME"; then ok "criado $d/$INI_NAME"; else bad "falhou ao escrever em $d"; fi
	done
	for b in $(list_bins); do
		sd=$(scan_dir "$b")
		{ [ -z "$sd" ] || [ "$sd" = "(none)" ]; } &&
			warn "$b não lê conf.d: coloque 'session.upload_progress.enabled = 0' em $(loaded_ini "$b") manualmente"
	done
	b=$(grep -rlsE 'php_(admin_)?(flag|value)[[ ].*session\.upload_progress\.enabled' /etc/php* /etc/opt /etc/apache2 /etc/httpd /usr/local/etc /opt/*/etc 2>/dev/null | grep -v "/$INI_NAME$")
	[ -n "$b" ] && warn "estes arquivos mexem em session.upload_progress no pool/vhost e podem anular o fix: $b"
	reload_all
	echo
	do_check
}

do_undo() {
	local d f n=0
	need_root undo
	printf '%sRemovendo a mitigação%s\n' "$B" "$N"
	for d in $(ini_dirs); do
		f="$d/$INI_NAME"
		[ -f "$f" ] && grep -q "$TAG" "$f" && rm -f "$f" && ok "removido $f" && n=$((n + 1))
	done
	[ "$n" = 0 ] && { echo "  nada para remover"; return 0; }
	reload_all
}

# ---------- block/unblock multipart (opcional) ----------

apache_ctl() { command -v apache2ctl || command -v apachectl || command -v httpd; }

# diretório de include do Apache onde largar o nosso .conf (Debian vs RHEL)
apache_conf_dir() {
	local d
	for d in /etc/apache2/conf-enabled /etc/httpd/conf.d /usr/local/apache2/conf/extra; do
		[ -d "$d" ] && { echo "$d"; return; }
	done
}

reload_apache() {
	local pid unit ctl
	pid=$(procs | awk -F'|' '$3 == "apache2" || $3 == "httpd" { print $1; exit }')
	unit=""; [ -n "$pid" ] && unit=$(service_unit "$pid")
	ctl=$(apache_ctl) || { warn "apachectl não encontrado: recarregue o Apache manualmente"; return 1; }
	"$ctl" -t >/dev/null 2>&1 || { bad "config do Apache inválida, NÃO recarreguei. Rode: $ctl -t"; return 1; }
	if [ -n "$unit" ] && command -v systemctl >/dev/null 2>&1; then
		if systemctl reload "$unit"; then ok "Apache recarregado ($unit)"; else bad "falhou: systemctl reload $unit"; fi
	elif "$ctl" -k graceful 2>/dev/null; then
		ok "Apache recarregado (graceful)"
	elif [ -z "$pid" ]; then
		ok "regra gravada (Apache não está rodando agora; entra no próximo start)"
	else
		warn "não consegui recarregar o Apache: faça manualmente"
	fi
}

# bloco <If> que recusa POST multipart, com allowlist opcional em PHP2SHELL_UPLOAD_PATHS.
# Casa qualquer Content-Type que começa com "multipart/" (pega as variantes ;  ,  e maiúsculas).
apache_block_conf() {
	local expr p allow=""
	expr='%{REQUEST_METHOD} == '"'"'POST'"'"' && %{HTTP:Content-Type} =~ m#^\s*multipart/#i'
	# allowlist: casa o caminho na fronteira de segmento (^/wp-admin pega /wp-admin e /wp-admin/... mas NÃO /wp-admin-evil)
	for p in ${PHP2SHELL_UPLOAD_PATHS:-}; do
		p=${p%/}; [ -n "$p" ] || p=/
		pe=$(printf '%s' "$p" | sed 's/[.\\]/\\&/g')
		allow="$allow${allow:+ || }%{REQUEST_URI} =~ m#^$pe(\$|/)#"
	done
	[ -n "$allow" ] && expr="$expr && ! ( $allow )"
	cat <<EOF
# $TAG - bloqueio temporário de POST multipart (PHP2Shell CVE-2026-109618 / CVE-2026-109619)
# Mitigação PARCIAL: quebra uploads. Para remover: php2shell.sh unblock
# allowlist (upload liberado): ${PHP2SHELL_UPLOAD_PATHS:-(nenhum)}
<If "$expr">
    Require all denied
</If>
EOF
}

nginx_block_snippet() {
	local p
	cat <<'EOF'
# --- cole dentro de cada bloco server {} que serve PHP (nginx não aplica global com segurança) ---
    set $p2s_block "";
    if ($request_method = POST) { set $p2s_block "M"; }
    if ($http_content_type ~* "^\s*multipart/") { set $p2s_block "${p2s_block}M"; }
EOF
	for p in ${PHP2SHELL_UPLOAD_PATHS:-}; do
		printf '    location ^~ %s { set $p2s_block ""; try_files $uri $uri/ /index.php?$query_string; }\n' "$p"
	done
	cat <<'EOF'
    if ($p2s_block = "MM") { return 403; }
# --- fim ---  depois: nginx -t && nginx -s reload
EOF
}

do_block() {
	local dir f
	need_root block
	printf '%sBloqueando POST multipart (mitigação parcial, quebra uploads)%s\n' "$B" "$N"
	if [ -n "${PHP2SHELL_UPLOAD_PATHS:-}" ]; then
		ok "upload liberado em: $PHP2SHELL_UPLOAD_PATHS"
	else
		warn "sem allowlist: TODO upload do site vai parar. Para liberar rotas: PHP2SHELL_UPLOAD_PATHS=\"/upload /wp-admin\" $0 block"
	fi
	dir=$(apache_conf_dir)
	if [ -n "$dir" ]; then
		f="$dir/$BLOCK_NAME"
		if apache_block_conf > "$f"; then ok "criado $f"; reload_apache; else bad "falhou ao escrever $f"; fi
	else
		warn "não achei diretório de config do Apache nesta máquina"
	fi
	if procs | grep -q '^[0-9]*|[^|]*|nginx|' || command -v nginx >/dev/null 2>&1; then
		warn "nginx detectado: o bloqueio dele não é automático. Cole o trecho abaixo e recarregue:"
		nginx_block_snippet
	fi
}

do_unblock() {
	local dir f n=0
	need_root unblock
	printf '%sRemovendo o bloqueio de multipart%s\n' "$B" "$N"
	for dir in /etc/apache2/conf-enabled /etc/httpd/conf.d /usr/local/apache2/conf/extra; do
		f="$dir/$BLOCK_NAME"
		[ -f "$f" ] && rm -f "$f" && ok "removido $f" && n=$((n + 1))
	done
	if [ "$n" -gt 0 ]; then reload_apache; else echo "  nada do Apache para remover"; fi
	command -v nginx >/dev/null 2>&1 && warn "se você colou o trecho no nginx, remova-o à mão e rode: nginx -t && nginx -s reload"
}

# ---------- containers ----------

do_docker() {
	local action="${1:-check}" rt list c rc worst=0 n=0
	[ $# -gt 0 ] && shift
	list=$*
	case $action in check | fix | undo | block | unblock) ;; *) die "uso: $0 docker check|fix|undo|block|unblock [container...]" ;; esac
	rt=$(command -v docker 2>/dev/null || command -v podman 2>/dev/null) || die "docker/podman não encontrado"
	[ -f "$0" ] || die "no modo docker rode a partir do arquivo (não via pipe)"
	[ -n "$list" ] || list=$("$rt" ps --format '{{.Names}}')
	for c in $list; do
		"$rt" exec "$c" sh -c 'for f in /usr/local/sbin/php-fpm /usr/sbin/php-fpm* /usr/local/bin/php /usr/bin/php*; do [ -x "$f" ] && exit 0; done; exit 1' \
			</dev/null >/dev/null 2>&1 || continue
		n=$((n + 1))
		printf '\n%s===== container %s =====%s\n' "$B" "$c" "$N"
		set -- -u 0 -i
		[ -n "${PHP2SHELL_FIXED:-}" ] && set -- "$@" -e "PHP2SHELL_FIXED=$PHP2SHELL_FIXED"
		[ -n "${PHP2SHELL_UPLOAD_PATHS:-}" ] && set -- "$@" -e "PHP2SHELL_UPLOAD_PATHS=$PHP2SHELL_UPLOAD_PATHS"
		"$rt" exec "$@" "$c" sh -s -- "$action" < "$0"; rc=$?
		[ "$rc" -gt "$worst" ] && worst=$rc
	done
	[ "$n" -gt 0 ] || echo "Nenhum container com PHP em execução."
	exit "$worst"
}

usage() { sed -n '2,/^$/p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; }

case ${1:-check} in
check) do_check ;;
fix) do_fix ;;
undo) do_undo ;;
block) do_block ;;
unblock) do_unblock ;;
docker) shift; do_docker "$@" ;;
-h | --help | help) usage ;;
*) usage; exit 4 ;;
esac
