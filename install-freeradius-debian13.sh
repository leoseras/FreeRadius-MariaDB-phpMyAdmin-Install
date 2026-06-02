#!/usr/bin/env bash
set -Eeuo pipefail

# Uso em um comando:
# curl -fsSL https://raw.githubusercontent.com/leoseras/FreeRadius-MariaDB-phpMyAdmin-Install/main/install-freeradius-debian13.sh | bash
#
# O script solicita a senha no terminal. Para automacao, voce tambem pode usar:
# curl -fsSL URL_DO_SCRIPT | RADIUS_INSTALL_PASSWORD='sua-senha' bash

RADIUS_DB="${RADIUS_DB:-radius}"
RADIUS_USER="${RADIUS_USER:-radius}"
FREERADIUS_DIR="${FREERADIUS_DIR:-/etc/freeradius/3.0}"
PASSWORD="${RADIUS_INSTALL_PASSWORD:-}"
MYSQL_ROOT_CNF=""
MYSQL_RADIUS_CNF=""

export DEBIAN_FRONTEND=noninteractive

log() {
  printf '\n==> %s\n' "$*"
}

die() {
  echo "Erro: $*" >&2
  exit 1
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "execute como root: su - ou sudo bash $0"
  fi
}

cleanup() {
  [[ -n "${MYSQL_ROOT_CNF}" && -f "${MYSQL_ROOT_CNF}" ]] && rm -f "${MYSQL_ROOT_CNF}"
  [[ -n "${MYSQL_RADIUS_CNF}" && -f "${MYSQL_RADIUS_CNF}" ]] && rm -f "${MYSQL_RADIUS_CNF}"
}

backup_file() {
  local file="$1"
  if [[ -f "${file}" && ! -f "${file}.orig" ]]; then
    cp "${file}" "${file}.orig"
  fi
}

validate_identifier() {
  local name="$1"
  local value="$2"

  if [[ ! "${value}" =~ ^[A-Za-z0-9_]+$ ]]; then
    die "${name} deve conter apenas letras, numeros e underscore"
  fi
}

prompt_password() {
  local first=""
  local second=""

  if [[ -n "${PASSWORD}" ]]; then
    return
  fi

  if [[ ! -r /dev/tty ]]; then
    die "nenhum terminal interativo disponivel. Defina RADIUS_INSTALL_PASSWORD para execucao automatizada"
  fi

  while true; do
    read -r -s -p "Senha para MariaDB, usuario radius e phpMyAdmin: " first < /dev/tty
    printf '\n' > /dev/tty
    read -r -s -p "Confirme a senha: " second < /dev/tty
    printf '\n' > /dev/tty

    if [[ -z "${first}" ]]; then
      echo "A senha nao pode ficar vazia." > /dev/tty
      continue
    fi

    if [[ "${first}" != "${second}" ]]; then
      echo "As senhas nao conferem. Tente novamente." > /dev/tty
      continue
    fi

    PASSWORD="${first}"
    break
  done
}

sql_escape() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\'/\'\'}
  printf '%s' "${value}"
}

freeradius_string_escape() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  printf '%s' "${value}"
}

sed_replacement_escape() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//&/\\&}
  value=${value//|/\\|}
  printf '%s' "${value}"
}

write_mysql_defaults() {
  MYSQL_ROOT_CNF="$(mktemp)"
  MYSQL_RADIUS_CNF="$(mktemp)"
  chmod 600 "${MYSQL_ROOT_CNF}" "${MYSQL_RADIUS_CNF}"

  cat > "${MYSQL_ROOT_CNF}" <<EOF
[client]
user=root
password=${PASSWORD}
EOF

  cat > "${MYSQL_RADIUS_CNF}" <<EOF
[client]
user=${RADIUS_USER}
password=${PASSWORD}
EOF
}

mysql_root() {
  mariadb --defaults-extra-file="${MYSQL_ROOT_CNF}" "$@"
}

mysql_radius() {
  mariadb --defaults-extra-file="${MYSQL_RADIUS_CNF}" "${RADIUS_DB}" "$@"
}

comment_mysql_tls_block() {
  local file="$1"
  local tmp

  tmp="$(mktemp)"
  awk '
    /^[[:space:]]*mysql[[:space:]]*\{/ {
      in_mysql = 1
    }

    in_mysql && /^[[:space:]]*tls[[:space:]]*\{/ {
      in_tls = 1
    }

    in_tls {
      print "##" $0
      if ($0 ~ /^[[:space:]]*\}[[:space:]]*$/) {
        in_tls = 0
      }
      next
    }

    in_mysql && /^[[:space:]]*\}[[:space:]]*$/ {
      in_mysql = 0
    }

    {
      print
    }
  ' "${file}" > "${tmp}"
  cat "${tmp}" > "${file}"
  rm -f "${tmp}"
}

configure_mariadb_root() {
  log "Configurando senha do root do MariaDB"

  if mariadb -uroot -e "SELECT 1" >/dev/null 2>&1; then
    mariadb -uroot <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '${SQL_PASSWORD}';
FLUSH PRIVILEGES;
EOF
  fi

  write_mysql_defaults
  mysql_root -e "SELECT 1" >/dev/null || die "nao foi possivel autenticar no MariaDB com a senha informada"
  : > /root/.mysql_history
}

require_root
trap cleanup EXIT

validate_identifier "RADIUS_DB" "${RADIUS_DB}"
validate_identifier "RADIUS_USER" "${RADIUS_USER}"
prompt_password

SQL_PASSWORD="$(sql_escape "${PASSWORD}")"
FREERADIUS_PASSWORD="$(freeradius_string_escape "${PASSWORD}")"
FREERADIUS_PASSWORD_SED="$(sed_replacement_escape "${FREERADIUS_PASSWORD}")"

if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  if [[ "${ID:-}" != "debian" ]]; then
    die "este script foi preparado para Debian 13"
  fi
  if [[ "${VERSION_ID:-}" != "13" ]]; then
    echo "Aviso: detectado Debian ${VERSION_ID:-desconhecido}; continuando mesmo assim."
  fi
fi

log "Atualizando sistema"
apt-get update
apt-get upgrade -y

log "Preconfigurando phpMyAdmin"
{
  printf 'phpmyadmin phpmyadmin/dbconfig-install boolean true\n'
  printf 'phpmyadmin phpmyadmin/app-password-confirm password %s\n' "${PASSWORD}"
  printf 'phpmyadmin phpmyadmin/mysql/admin-pass password %s\n' "${PASSWORD}"
  printf 'phpmyadmin phpmyadmin/mysql/app-pass password %s\n' "${PASSWORD}"
  printf 'phpmyadmin phpmyadmin/reconfigure-webserver multiselect apache2\n'
} | debconf-set-selections

log "Instalando Apache, PHP, MariaDB, phpMyAdmin e FreeRADIUS"
apt-get install -y \
  apache2 apache2-utils libapache2-mod-php \
  php php-mysql php-cli php-pear php-gmp php-gd php-bcmath \
  php-mbstring php-curl php-xml php-zip \
  mariadb-server mariadb-client phpmyadmin \
  freeradius freeradius-mysql freeradius-utils

log "Ajustando Apache"
a2enmod rewrite headers
sed -i 's/ServerTokens OS/ServerTokens Prod/' /etc/apache2/conf-available/security.conf
sed -i 's/ServerSignature On/ServerSignature Off/' /etc/apache2/conf-available/security.conf
systemctl restart apache2

configure_mariadb_root

log "Criando banco e usuario do FreeRADIUS"
mysql_root <<EOF
CREATE DATABASE IF NOT EXISTS ${RADIUS_DB};
CREATE USER IF NOT EXISTS '${RADIUS_USER}'@'localhost' IDENTIFIED BY '${SQL_PASSWORD}';
ALTER USER '${RADIUS_USER}'@'localhost' IDENTIFIED BY '${SQL_PASSWORD}';
GRANT ALL PRIVILEGES ON ${RADIUS_DB}.* TO '${RADIUS_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF

if [[ ! -d "${FREERADIUS_DIR}" ]]; then
  die "diretorio ${FREERADIUS_DIR} nao encontrado. Verifique a versao/pacote do FreeRADIUS"
fi

log "Importando schema SQL do FreeRADIUS"
if ! mysql_radius -e 'SHOW TABLES LIKE "radcheck";' | grep -q radcheck; then
  mysql_radius < "${FREERADIUS_DIR}/mods-config/sql/main/mysql/schema.sql"
fi

log "Fazendo backup dos arquivos de configuracao"
backup_file "${FREERADIUS_DIR}/radiusd.conf"
backup_file "${FREERADIUS_DIR}/mods-available/sql"
backup_file "${FREERADIUS_DIR}/mods-available/eap"
backup_file "${FREERADIUS_DIR}/sites-available/default"
backup_file "${FREERADIUS_DIR}/sites-available/inner-tunnel"
backup_file "${FREERADIUS_DIR}/mods-available/sqlippool"

log "Configurando logs de autenticacao"
sed -i -E '/^[[:space:]]*stripped_names = no/s/(stripped_names = )no/\1yes/' "${FREERADIUS_DIR}/radiusd.conf"
sed -i -E '/^[[:space:]]*auth = no/s/(auth = )no/\1yes/' "${FREERADIUS_DIR}/radiusd.conf"
sed -i -E '/^[[:space:]]*auth_badpass = no/s/(auth_badpass = )no/\1yes/' "${FREERADIUS_DIR}/radiusd.conf"
sed -i -E '/^[[:space:]]*auth_goodpass = no/s/(auth_goodpass = )no/\1yes/' "${FREERADIUS_DIR}/radiusd.conf"

log "Configurando modulo SQL"
SQL_CONF="${FREERADIUS_DIR}/mods-available/sql"
sed -i -E 's|^([[:space:]]*)driver = "rlm_sql_null"|\1driver = "rlm_sql_mysql"|' "${SQL_CONF}"
sed -i -E 's|^([[:space:]]*)dialect = "sqlite"|\1dialect = "mysql"|' "${SQL_CONF}"
sed -i -E 's|^#?([[:space:]]*)server = .*|\1server = "localhost"|' "${SQL_CONF}"
sed -i -E 's|^#?([[:space:]]*)port = .*|\1port = 3306|' "${SQL_CONF}"
sed -i -E "s|^#?([[:space:]]*)login = .*|\\1login = \"${RADIUS_USER}\"|" "${SQL_CONF}"
sed -i -E "s|^#?([[:space:]]*)password = .*|\\1password = \"${FREERADIUS_PASSWORD_SED}\"|" "${SQL_CONF}"
sed -i -E "s|^#?([[:space:]]*)radius_db = .*|\\1radius_db = \"${RADIUS_DB}\"|" "${SQL_CONF}"
sed -i -E 's|^#?([[:space:]]*)read_clients = .*|\1read_clients = yes|' "${SQL_CONF}"
comment_mysql_tls_block "${SQL_CONF}"

ln -sfn "${FREERADIUS_DIR}/mods-available/sql" "${FREERADIUS_DIR}/mods-enabled/sql"
ln -sfn "${FREERADIUS_DIR}/mods-available/sqlippool" "${FREERADIUS_DIR}/mods-enabled/sqlippool"

log "Ajustando EAP/TLS conforme tutorial"
sed -i 's/disable_tlsv1_2 = yes/disable_tlsv1_2 = no/' "${FREERADIUS_DIR}/mods-available/eap"
sed -i 's/disable_tlsv1_1 = yes/disable_tlsv1_1 = no/' "${FREERADIUS_DIR}/mods-available/eap"
sed -i 's/disable_tlsv1 = yes/disable_tlsv1 = no/' "${FREERADIUS_DIR}/mods-available/eap"
sed -i '/disable_tlsv1/s/^#//g' "${FREERADIUS_DIR}/mods-available/eap"
sed -i 's/tls_min_version = "1.2"/tls_min_version = "1.0"/' "${FREERADIUS_DIR}/mods-available/eap"

log "Ajustando site default"
DEFAULT_SITE="${FREERADIUS_DIR}/sites-available/default"
sed -i -E '/^[[:space:]]*(digest|suffix|files|-ldap|exec|detail|unix|attr_filter\.accounting_response)\b/s/^/## /' "${DEFAULT_SITE}"
sed -i -E 's/^([[:space:]]*)-sql/\1sql/' "${DEFAULT_SITE}"
sed -i -E '/^[[:space:]]*#.*sqlippool/s/^([[:space:]]*)#[[:space:]]*/\1/' "${DEFAULT_SITE}"

log "Ajustando inner-tunnel"
INNER_TUNNEL="${FREERADIUS_DIR}/sites-available/inner-tunnel"
sed -i -E '/^[[:space:]]*(suffix|files|-ldap|radutmp)\b/s/^/## /' "${INNER_TUNNEL}"
sed -i -E 's/^([[:space:]]*)-sql/\1sql/' "${INNER_TUNNEL}"

log "Configurando sqlippool"
SQLIPPOOL_CONF="${FREERADIUS_DIR}/mods-available/sqlippool"
sed -i -E 's|^[[:space:]]*#?[[:space:]]*allow_duplicates = .*|        allow_duplicates = no|' "${SQLIPPOOL_CONF}"
sed -i -E 's|^[[:space:]]*pool_key = "%\{NAS-Port\}"|#       pool_key = "%{NAS-Port}"|' "${SQLIPPOOL_CONF}"
sed -i -E 's|^[[:space:]]*# *pool_key = "%\{Calling-Station-Id\}"|        pool_key = "%{Calling-Station-Id}"|' "${SQLIPPOOL_CONF}"
sed -i 's/lease_duration = 3600/lease_duration = 1200/' "${SQLIPPOOL_CONF}"

mysql_radius < "${FREERADIUS_DIR}/mods-config/sql/ippool/mysql/schema.sql" || true
mysql_radius < "${FREERADIUS_DIR}/mods-config/sql/ippool/mysql/procedure.sql" || true
backup_file "${FREERADIUS_DIR}/mods-config/sql/ippool/mysql/queries.conf"

mysql_radius -e "ALTER TABLE radippool ADD COLUMN action VARCHAR(20) NULL AFTER pool_key;" || true

cat > "${FREERADIUS_DIR}/mods-config/sql/ippool/mysql/queries.conf" <<'EOF'
skip_locked = "SKIP LOCKED"
pool_next = "cgnat"

allocate_existing = "\
	SELECT framedipaddress FROM ${ippool_table} \
	WHERE pool_name = '%{control:${pool_name}}' \
	AND username = '%{User-Name}' \
	ORDER BY expiry_time DESC \
	LIMIT 1 \
	FOR UPDATE ${skip_locked}"

allocate_find = "\
	SELECT framedipaddress \
	FROM ${ippool_table} \
	WHERE ( \
	    CASE \
	        WHEN ( \
	            SELECT COUNT(framedipaddress) \
	            FROM radippool \
	            WHERE pool_name = '%{control:Pool-Name}' AND expiry_time < NOW() \
	            LIMIT 1 \
	        ) > 0 THEN \
	            (pool_name = '%{control:Pool-Name}' AND expiry_time < NOW()) \
	        ELSE \
	            CASE \
	                WHEN ( \
	                    SELECT COUNT(framedipaddress) \
	                    FROM radippool \
	                    WHERE pool_name = '${pool_next}' AND username = '%{User-Name}' \
	                    LIMIT 1 \
	                ) > 0 THEN \
	                    (pool_name = '${pool_next}' AND username = '%{User-Name}') \
	                ELSE \
	                    (pool_name = '${pool_next}' AND expiry_time < NOW()) \
	            END \
	    END \
	) \
	ORDER BY expiry_time ASC, RAND() \
	LIMIT 1 \
	FOR UPDATE ${skip_locked}"

pool_check = "\
	SELECT id \
	FROM ${ippool_table} \
	WHERE pool_name='%{control:${pool_name}}' \
	LIMIT 1"

allocate_update = "\
	UPDATE ${ippool_table} \
	SET \
		nasipaddress = '%{NAS-IP-Address}', pool_key = '${pool_key}', \
		callingstationid = '%{Calling-Station-Id}', \
		username = '%{User-Name}', expiry_time = NOW() + INTERVAL ${lease_duration} SECOND, \
		action = 'allocate_update' \
	WHERE framedipaddress = '%I'"

start_update = "\
	UPDATE ${ippool_table} \
	SET \
		expiry_time = NOW() + INTERVAL ${lease_duration} SECOND, \
		action = 'start_update' \
	WHERE nasipaddress = '%{NAS-IP-Address}' \
	AND pool_key = '${pool_key}' \
	AND username = '%{User-Name}' \
	AND callingstationid = '%{Calling-Station-Id}' \
	AND framedipaddress = '%{${attribute_name}}'"

stop_clear = "\
	UPDATE ${ippool_table} \
	SET \
	    nasipaddress = '', \
	    pool_key = 'waiting', \
	    callingstationid = '', \
		expiry_time = NOW() - INTERVAL 2 SECOND, \
		action = 'stop_clear' \
	WHERE nasipaddress = '%{%{Nas-IP-Address}:-%{Nas-IPv6-Address}}' \
	AND pool_key = '${pool_key}' \
	AND username = '%{User-Name}' \
	AND callingstationid = '%{Calling-Station-Id}' \
	AND framedipaddress = '%{${attribute_name}}'"

alive_update = "\
	UPDATE ${ippool_table} \
	SET \
		expiry_time = NOW() + INTERVAL ${lease_duration} SECOND, \
		action = 'alive_update' \
	WHERE nasipaddress = '%{%{Nas-IP-Address}:-%{Nas-IPv6-Address}}' \
	AND pool_key = '${pool_key}' \
	AND username = '%{User-Name}' \
	AND callingstationid = '%{Calling-Station-Id}' \
	AND framedipaddress = '%{${attribute_name}}'"

on_clear = "\
	UPDATE ${ippool_table} \
	SET \
		expiry_time = NOW() + INTERVAL ${lease_duration} SECOND, \
		action = 'on_clear' \
	WHERE nasipaddress = '%{%{Nas-IP-Address}:-%{Nas-IPv6-Address}}'"

off_clear = "\
	UPDATE ${ippool_table} \
	SET \
		expiry_time = NOW(), \
		action = 'off_clear' \
	WHERE nasipaddress = '%{%{Nas-IP-Address}:-%{Nas-IPv6-Address}}'"
EOF

log "Habilitando e reiniciando FreeRADIUS"
systemctl enable freeradius
freeradius -C
systemctl restart freeradius

log "Concluido"
echo "phpMyAdmin: http://IP_DO_SERVIDOR/phpmyadmin/"
echo "Banco Radius: ${RADIUS_DB}"
echo "Usuario Radius: ${RADIUS_USER}"
