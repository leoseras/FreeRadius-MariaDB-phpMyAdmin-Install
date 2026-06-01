# FreeRadius-MariaDB-phpMyAdmin-Install

Script de instalacao automatizada para Debian 13 com:

- Apache + PHP
- MariaDB
- phpMyAdmin
- FreeRADIUS
- FreeRADIUS SQL com MariaDB
- FreeRADIUS sqlippool

Baseado no tutorial do Remontti:
https://blog.remontti.com.br/7784

## Uso

Execute como root em um Debian 13 limpo:

```bash
curl -fsSL https://SEU_DOMINIO/install-freeradius-debian13.sh | bash
```

Ou baixe e execute localmente:

```bash
wget https://SEU_DOMINIO/install-freeradius-debian13.sh
bash install-freeradius-debian13.sh
```

## Observacao

Revise as senhas e parametros antes de usar em producao.
