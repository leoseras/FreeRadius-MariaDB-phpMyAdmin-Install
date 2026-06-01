#!/usr/bin/env bash
set -Eeuo pipefail

# Uso em um comando, depois de hospedar este arquivo:
# curl -fsSL https://SEU_DOMINIO/install-freeradius-debian13.sh | bash

PASSWORD='C@Ca0823$!'
RADIUS_DB='radius'
RADIUS_USER='radius'
FREERADIUS_DIR='/etc/freeradius/3.0'

export DEBIAN_FRONTEND=noninteractive

log() {
  printf '\n==> %s\n' "$*"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Execute como root: su - ou sudo bash $0" >&2
    exit 1
  fi
}

backup_file() {
  local file="$1"
  if [[ -f "$file" && ! -f "${file}.orig" ]]; then
    cp "$file" "${file}.orig"
  fi
}

mysql_root() {
  mariadb -uroot -p"${PASSWORD}" "$@"
}

mysql_radius() {
  mariadb -u"${RADIUS_USER}" -p"${PASSWORD}" "${RADIUS_DB}" "$@"
}

require_root

if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  if [[ "${ID:-}" != "debian" ]]; then
    echo "Este script foi preparado para Debian 13." >&2
    exit 1
  fi
  if [[ "${VERSION_ID:-}" != "13" ]]; then
    echo "Aviso: detectado Debian ${VERSION_ID:-desconhecido}; continuando mesmo assim."
  fi
fi

log "Atualizando sistema"
apt-get update
apt-get upgrade -y

log "Preconfigurando phpMyAdmin"
debconf-set-selections <<EOF
phpmyadmin phpmyadmin/dbconfig-install boolean true
phpmyadmin phpmyadmin/app-password-confirm password ${PASSWORD}
phpmyadmin phpmyadmin/mysql/admin-pass password ${PASSWORD}
phpmyadmin phpmyadmin/mysql/app-pass password ${PASSWORD}
phpmyadmin phpmyadmin/reconfigure-webserver multiselect apache2
EOF

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

log "Configurando senha do root do MariaDB"
mariadb -uroot <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '${PASSWORD}';
FLUSH PRIVILEGES;
EOF
: > /root/.mysql_history

log "Criando banco e usuário do FreeRADIUS"
mysql_root <<EOF
CREATE DATABASE IF NOT EXISTS ${RADIUS_DB};
CREATE USER IF NOT EXISTS '${RADIUS_USER}'@'localhost' IDENTIFIED BY '${PASSWORD}';
ALTER USER '${RADIUS_USER}'@'localhost' IDENTIFIED BY '${PASSWORD}';
GRANT ALL PRIVILEGES ON ${RADIUS_DB}.* TO '${RADIUS_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF

if [[ ! -d "${FREERADIUS_DIR}" ]]; then
  echo "Diretório ${FREERADIUS_DIR} não encontrado. Verifique a versão/pacote do FreeRADIUS." >&2
  exit 1
fi

log "Importando schema SQL do FreeRADIUS"
if ! mysql_radius -e 'SHOW TABLES LIKE "radcheck";' | grep -q radcheck; then
  mysql_radius < "${FREERADIUS_DIR}/mods-config/sql/main/mysql/schema.sql"
fi

log "Fazendo backup dos arquivos de configuração"
backup_file "${FREERADIUS_DIR}/radiusd.conf"
backup_file "${FREERADIUS_DIR}/mods-available/sql"
backup_file "${FREERADIUS_DIR}/mods-available/eap"
backup_file "${FREERADIUS_DIR}/sites-available/default"
backup_file "${FREERADIUS_DIR}/sites-available/inner-tunnel"
backup_file "${FREERADIUS_DIR}/mods-available/sqlippool"

log "Configurando logs de autenticação"
sed -i '/^\s*stripped_names = no/s/^\(\s*stripped_names =\) no/\1 yes/g' "${FREERADIUS_DIR}/radiusd.conf"
sed -i '/^\s*auth = no/s/^\(\s*auth =\) no/\1 yes/g' "${FREERADIUS_DIR}/radiusd.conf"
sed -i '/^\s*auth_badpass = no/s/^\(\s*auth_badpass =\) no/\1 yes/g' "${FREERADIUS_DIR}/radiusd.conf"
sed -i '/^\s*auth_goodpass = no/s/^\(\s*auth_goodpass =\) no/\1 yes/g' "${FREERADIUS_DIR}/radiusd.conf"

log "Configurando módulo SQL"
sed -i 's/driver = "rlm_sql_null"/driver = "rlm_sql_mysql"/' "${FREERADIUS_DIR}/mods-available/sql"
sed -i 's/dialect = "sqlite"/dialect = "mysql"/' "${FREERADIUS_DIR}/mods-available/sql"
sed -i '/server = "localhost"/s/^#//g' "${FREERADIUS_DIR}/mods-available/sql"
sed -i '/port = 3306/s/^#//g' "${FREERADIUS_DIR}/mods-available/sql"
sed -i '/login = "radius"/s/^#//g' "${FREERADIUS_DIR}/mods-available/sql"
sed -i '/password = "radpass"/s/^#//g' "${FREERADIUS_DIR}/mods-available/sql"
sed -i '/read_clients = yes/s/^#//g' "${FREERADIUS_DIR}/mods-available/sql"
sed -i "s/radpass/${PASSWORD//\//\\/}/" "${FREERADIUS_DIR}/mods-available/sql"
sed -i '84,102 {s/^/##/}' "${FREERADIUS_DIR}/mods-available/sql"

ln -sfn "${FREERADIUS_DIR}/mods-available/sql" "${FREERADIUS_DIR}/mods-enabled/sql"
ln -sfn "${FREERADIUS_DIR}/mods-available/sqlippool" "${FREERADIUS_DIR}/mods-enabled/sqlippool"

log "Ajustando EAP/TLS conforme tutorial"
sed -i 's/disable_tlsv1_2 = yes/disable_tlsv1_2 = no/' "${FREERADIUS_DIR}/mods-available/eap"
sed -i 's/disable_tlsv1_1 = yes/disable_tlsv1_1 = no/' "${FREERADIUS_DIR}/mods-available/eap"
sed -i 's/disable_tlsv1 = yes/disable_tlsv1 = no/' "${FREERADIUS_DIR}/mods-available/eap"
sed -i '/disable_tlsv1/s/^#//g' "${FREERADIUS_DIR}/mods-available/eap"
sed -i 's/tls_min_version = "1.2"/tls_min_version = "1.0"/' "${FREERADIUS_DIR}/mods-available/eap"

log "Ajustando site default"
sed -i '/^[[:space:]]*digest/s/^/## /' "${FREERADIUS_DIR}/sites-available/default"
sed -i '/^[[:space:]]*suffix/s/^/## /' "${FREERADIUS_DIR}/sites-available/default"
sed -i '/^[[:space:]]*files/s/^/## /' "${FREERADIUS_DIR}/sites-available/default"
sed -i '/^[[:space:]]*-ldap/s/^/## /' "${FREERADIUS_DIR}/sites-available/default"
sed -i '/^[[:space:]]*exec/s/^/## /' "${FREERADIUS_DIR}/sites-available/default"
sed -i '/^[[:space:]]*detail/s/^/## /' "${FREERADIUS_DIR}/sites-available/default"
sed -i '/^[[:space:]]*unix/s/^/## /' "${FREERADIUS_DIR}/sites-available/default"
sed -i '/^[[:space:]]*attr_filter.accounting_response/s/^/## /' "${FREERADIUS_DIR}/sites-available/default"
sed -i 's/-sql/sql/' "${FREERADIUS_DIR}/sites-available/default"
sed -i '741 s/# *//' "${FREERADIUS_DIR}/sites-available/default"
sed -i '958,970 {s/^/##/}' "${FREERADIUS_DIR}/sites-available/default"
sed -i '/^[[:space:]]*#.*sqlippool/s/^#//' "${FREERADIUS_DIR}/sites-available/default"

log "Ajustando inner-tunnel"
sed -i '/^[[:space:]]*suffix/s/^/## /' "${FREERADIUS_DIR}/sites-available/inner-tunnel"
sed -i '/^[[:space:]]*files/s/^/## /' "${FREERADIUS_DIR}/sites-available/inner-tunnel"
sed -i '/^[[:space:]]*-ldap/s/^/## /' "${FREERADIUS_DIR}/sites-available/inner-tunnel"
sed -i 's/-sql/sql/' "${FREERADIUS_DIR}/sites-available/inner-tunnel"
sed -i '/^[[:space:]]*radutmp/s/^/## /' "${FREERADIUS_DIR}/sites-available/inner-tunnel"
sed -i '266 s/# *//' "${FREERADIUS_DIR}/sites-available/inner-tunnel"
sed -i '336,361 {s/^/##/}' "${FREERADIUS_DIR}/sites-available/inner-tunnel"
sed -i '370,381 {s/^/##/}' "${FREERADIUS_DIR}/sites-available/inner-tunnel"

log "Configurando sqlippool"
sed -i '76 {s/^/#/}' "${FREERADIUS_DIR}/mods-available/sqlippool"
sed -i '77 s/# *//' "${FREERADIUS_DIR}/mods-available/sqlippool"
sed -i '66 s/# *//' "${FREERADIUS_DIR}/mods-available/sqlippool"
sed -i 's/lease_duration = 3600/lease_duration = 1200/' "${FREERADIUS_DIR}/mods-available/sqlippool"

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
systemctl restart freeradius

log "Validando configuração"
freeradius -C

log "Concluído"
echo "phpMyAdmin: http://IP_DO_SERVIDOR/phpmyadmin/"
echo "Banco Radius: ${RADIUS_DB}"
echo "Usuário Radius: ${RADIUS_USER}"
