#!/bin/sh
# Laboratório que valida o php2shell.sh em stacks reais (Docker).
#
#   tests/lab.sh up      sobe os ambientes (laravel, wordpress, debian, ubuntu, rocky, alpine)
#   tests/lab.sh test    roda o roteiro em cada um: probe -> fix -> probe -> upload/app -> undo -> probe
#   tests/lab.sh down    remove tudo
#
# O "probe" não explora nada: manda um POST multipart com PHP_SESSION_UPLOAD_PROGRESS e um cookie de sessão
# e verifica se o PHP criou o arquivo sess_<id> no disco. Isso só acontece com session.upload_progress ligado,
# e acontece antes do código da aplicação (vale até para rota que responde 404/405/419).

set -u
cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
LAB=${LAB_DIR:-$ROOT/tests/.lab}
NET=p2s-lab
ENVS="laravel wordpress debian ubuntu rocky alpine"

port() { case $1 in laravel) echo 18081 ;; wordpress) echo 18082 ;; debian) echo 18083 ;; ubuntu) echo 18084 ;; rocky) echo 18085 ;; alpine) echo 18086 ;; esac; }
php_ctr() { echo "lab-$1"; }
upload_path() { case $1 in laravel) echo /upload-test ;; *) echo /p2s-upload.php ;; esac; }

UPLOAD_PHP='<?php header("Content-Type: application/json"); echo json_encode(["files" => count($_FILES), "size" => $_FILES["file"]["size"] ?? null]);'

nginx_conf() { # $1=upstream $2=root
	cat <<EOF
server {
  listen 80;
  root $2;
  index index.php;
  client_max_body_size 20m;
  location / { try_files \$uri \$uri/ /index.php?\$query_string; }
  location ~ \.php\$ {
    fastcgi_pass $1:9000;
    fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    include fastcgi_params;
  }
}
EOF
}

build_distro_images() {
	docker build -q -t p2s-debian - >/dev/null <<'EOF'
FROM debian:trixie
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq php-fpm nginx procps >/dev/null
EOF
	docker build -q -t p2s-ubuntu - >/dev/null <<'EOF'
FROM ubuntu:24.04
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq php-fpm libapache2-mod-php apache2 procps >/dev/null
EOF
	docker build -q -t p2s-rocky - >/dev/null <<'EOF'
FROM rockylinux:9
RUN dnf -y -q module enable php:8.2 && dnf -y -q install php-fpm httpd procps-ng >/dev/null && dnf clean all >/dev/null
EOF
}

laravel_app() {
	[ -f "$LAB/laravel/artisan" ] && return
	mkdir -p "$LAB"
	docker run --rm -u "$(id -u):$(id -g)" -e COMPOSER_HOME=/tmp/ch -v "$LAB:/app" -w /app composer:2 \
		create-project laravel/laravel laravel --prefer-dist --no-interaction --no-progress >/dev/null 2>&1
}

laravel_prepare() {
	grep -q upload-test "$LAB/laravel/routes/web.php" || cat >> "$LAB/laravel/routes/web.php" <<'EOF'

Route::post('/upload-test', function (\Illuminate\Http\Request $r) {
    return response()->json(['files' => count($r->allFiles()), 'size' => $r->file('file')?->getSize()]);
})->withoutMiddleware([\Illuminate\Foundation\Http\Middleware\PreventRequestForgery::class, \Illuminate\Foundation\Http\Middleware\ValidateCsrfToken::class]);
EOF
	chmod -R a+rwX "$LAB/laravel/storage" "$LAB/laravel/bootstrap/cache" "$LAB/laravel/database"
}

up() {
	build_distro_images
	laravel_app && laravel_prepare
	mkdir -p "$LAB/plain"
	printf '<?php echo "ok ", PHP_VERSION, " ", PHP_SAPI;\n' > "$LAB/plain/index.php"
	printf '%s\n' "$UPLOAD_PHP" > "$LAB/plain/p2s-upload.php"
	nginx_conf lab-laravel /var/www/html/public > "$LAB/nginx-laravel.conf"
	nginx_conf lab-alpine /var/www/html > "$LAB/nginx-alpine.conf"
	docker network create "$NET" >/dev/null 2>&1

	docker run -d --name lab-laravel --network "$NET" -v "$LAB/laravel:/var/www/html" php:8.4-fpm >/dev/null
	docker run -d --name lab-laravel-web --network "$NET" -p 127.0.0.1:18081:80 -v "$LAB/laravel:/var/www/html:ro" \
		-v "$LAB/nginx-laravel.conf:/etc/nginx/conf.d/default.conf:ro" nginx:stable-alpine >/dev/null

	docker run -d --name lab-wordpress-db --network "$NET" -e MARIADB_ROOT_PASSWORD=lab -e MARIADB_DATABASE=wp \
		-e MARIADB_USER=wp -e MARIADB_PASSWORD=wp mariadb:11 >/dev/null
	docker run -d --name lab-wordpress --network "$NET" -p 127.0.0.1:18082:80 -e WORDPRESS_DB_HOST=lab-wordpress-db \
		-e WORDPRESS_DB_USER=wp -e WORDPRESS_DB_PASSWORD=wp -e WORDPRESS_DB_NAME=wp wordpress:php8.3-apache >/dev/null

	docker run -d --name lab-debian --network "$NET" -p 127.0.0.1:18083:80 -v "$LAB/plain:/var/www/html:ro" p2s-debian sh -c '
		printf "server { listen 80 default_server; root /var/www/html; index index.php; client_max_body_size 20m;
		  location ~ \\.php\$ { include snippets/fastcgi-php.conf; fastcgi_pass unix:/run/php/php8.4-fpm.sock; } }" \
		  > /etc/nginx/sites-enabled/default
		mkdir -p /run/php && php-fpm8.4 -D && exec nginx -g "daemon off;"' >/dev/null

	docker run -d --name lab-ubuntu --network "$NET" -p 127.0.0.1:18084:80 -v "$LAB/plain:/srv/plain:ro" p2s-ubuntu sh -c '
		rm -f /var/www/html/index.html && cp /srv/plain/*.php /var/www/html/
		mkdir -p /run/php && php-fpm8.3 -D && exec apachectl -D FOREGROUND' >/dev/null

	docker run -d --name lab-rocky --network "$NET" -p 127.0.0.1:18085:80 -v "$LAB/plain:/srv/plain:ro" p2s-rocky sh -c '
		cp /srv/plain/*.php /var/www/html/ && mkdir -p /run/php-fpm && php-fpm -D && exec httpd -DFOREGROUND' >/dev/null

	docker run -d --name lab-alpine --network "$NET" -v "$LAB/plain:/var/www/html:ro" php:8.3-fpm-alpine >/dev/null
	docker run -d --name lab-alpine-web --network "$NET" -p 127.0.0.1:18086:80 -v "$LAB/plain:/var/www/html:ro" \
		-v "$LAB/nginx-alpine.conf:/etc/nginx/conf.d/default.conf:ro" nginx:stable-alpine >/dev/null

	for e in $ENVS; do
		i=0
		until [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$(port "$e")/")" != 000 ] || [ $i -ge 90 ]; do sleep 1; i=$((i + 1)); done
	done
	# o entrypoint do WordPress copia os arquivos na primeira subida
	i=0; until docker exec lab-wordpress test -f /var/www/html/wp-login.php 2>/dev/null || [ $i -ge 60 ]; do sleep 1; i=$((i + 1)); done
	printf '%s\n' "$UPLOAD_PHP" | docker exec -i lab-wordpress sh -c 'cat > /var/www/html/p2s-upload.php'
	echo "lab no ar: $(for e in $ENVS; do printf '%s=http://127.0.0.1:%s ' "$e" "$(port "$e")"; done)"
}

down() {
	for e in $ENVS; do docker rm -f "lab-$e" "lab-$e-web" "lab-$e-db" >/dev/null 2>&1; done
	docker network rm "$NET" >/dev/null 2>&1
	echo "lab removido"
}

# ---------- roteiro ----------

PAYLOAD=$LAB/payload.bin

# imprime "ON" se o PHP criou o arquivo de sessão de upload progress, "OFF" se não
probe() {
	local e="$1" id f
	id=p2s$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')
	curl -s -o /dev/null -b "PHPSESSID=$id" -F "PHP_SESSION_UPLOAD_PROGRESS=probe" -F "file=@$PAYLOAD" \
		"http://127.0.0.1:$(port "$e")/"
	f=$(docker exec "$(php_ctr "$e")" sh -c "find / -xdev -name 'sess_$id' 2>/dev/null | head -n1")
	if [ -n "$f" ]; then echo ON; else echo OFF; fi
}

upload_ok() {
	curl -s -F "file=@$PAYLOAD" "http://127.0.0.1:$(port "$1")$(upload_path "$1")" | grep -q '"size":65536'
}

app_code() { curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$(port "$1")/"; }

script() { # ação ambiente -> código de saída do php2shell.sh
	"$ROOT/php2shell.sh" docker "$1" "$(php_ctr "$2")" > "$LAB/out-$2-$1.txt" 2>&1
	echo $?
}

PASS=0 FAIL=0
expect() { # descrição obtido esperado
	if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); printf '    ok    %-38s %s\n' "$1" "$2"
	else FAIL=$((FAIL + 1)); printf '    FALHA %-38s obtido=%s esperado=%s\n' "$1" "$2" "$3"; fi
}

mp_post() { # ambiente caminho -> http_code de um POST multipart
	curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: multipart/form-data, boundary=x' --data 'a=b' "http://127.0.0.1:$(port "$1")$2"
}

test_block() {
	local e="$1" up code
	up=$(upload_path "$e")
	printf '  -- block (multipart) --\n'
	expect "GET / antes do block"            "$(app_code "$e" | sed 's/^302$/200/')" 200
	PHP2SHELL_UPLOAD_PATHS="$up" "$ROOT/php2shell.sh" docker block "$(php_ctr "$e")" > "$LAB/out-$e-block.txt" 2>&1
	expect "POST multipart fora da allowlist" "$(mp_post "$e" /nao-existe.php)" 403
	expect "upload na rota liberada"          "$(upload_ok "$e" && echo 200 || echo bloq)" 200
	expect "GET / segue respondendo"          "$(app_code "$e" | sed 's/^302$/200/')" 200
	"$ROOT/php2shell.sh" docker unblock "$(php_ctr "$e")" > "$LAB/out-$e-unblock.txt" 2>&1
	code=$(mp_post "$e" /nao-existe.php)
	expect "POST multipart não é mais 403 após unblock" "$([ "$code" = 403 ] && echo BLOQ || echo ok)" ok
}

test_all() {
	head -c 65536 /dev/zero > "$PAYLOAD"
	for e in $ENVS; do
		printf '\n== %s (%s)\n' "$e" "$(curl -s "http://127.0.0.1:$(port "$e")/" | head -c 60 | tr -d '\n' | sed 's/<[^>]*>//g')"
		expect "probe antes do fix"            "$(probe "$e")"          ON
		expect "check antes do fix (exit)"     "$(script check "$e")"   3
		expect "fix (exit = check final)"      "$(script fix "$e")"     2
		expect "probe depois do fix"           "$(probe "$e")"          OFF
		expect "upload continua funcionando"   "$(upload_ok "$e" && echo sim || echo nao)" sim
		expect "app responde (HTTP)"           "$(app_code "$e" | sed 's/^302$/200/')" 200
		expect "check depois do fix (exit)"    "$(script check "$e")"   2
		expect "undo (exit)"                   "$(script undo "$e")"    0
		expect "probe depois do undo"          "$(probe "$e")"          ON
		if [ "$e" = debian ]; then
			docker exec lab-debian sh -c 'kill "$(cat /run/php/php8.4-fpm.pid)"'; sleep 1
			expect "check com php-fpm parado (exit)" "$(script check "$e")" 1
			docker exec lab-debian php-fpm8.4 -D
		fi
		case $e in ubuntu | wordpress) test_block "$e" ;; esac
	done
	printf '\n%s ok, %s falhas (saídas completas em %s/out-*.txt)\n' "$PASS" "$FAIL" "$LAB"
	[ "$FAIL" = 0 ]
}

case ${1:-} in
up) up ;;
test) test_all ;;
down) down ;;
*) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
