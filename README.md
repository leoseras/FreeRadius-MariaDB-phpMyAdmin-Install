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
curl -fsSL https://raw.githubusercontent.com/leoseras/FreeRadius-MariaDB-phpMyAdmin-Install/main/install-freeradius-debian13.sh | bash
```

O instalador vai solicitar a senha no terminal e confirmar antes de continuar.
Essa senha sera aplicada ao root do MariaDB, ao usuario `radius` e ao phpMyAdmin.

Se o Debian minimo ainda nao tiver `curl`:

```bash
apt-get update && apt-get install -y curl
```

Para executar por SSH mantendo o prompt de senha, force TTY:

```bash
ssh -tt root@IP_DO_SERVIDOR 'curl -fsSL https://raw.githubusercontent.com/leoseras/FreeRadius-MariaDB-phpMyAdmin-Install/main/install-freeradius-debian13.sh | bash'
```

Ou baixe e execute localmente:

```bash
wget https://SEU_DOMINIO/install-freeradius-debian13.sh
bash install-freeradius-debian13.sh
```

Para automacao sem prompt interativo:

```bash
curl -fsSL https://raw.githubusercontent.com/leoseras/FreeRadius-MariaDB-phpMyAdmin-Install/main/install-freeradius-debian13.sh | RADIUS_INSTALL_PASSWORD='sua-senha' bash
```

## Observacao

Revise as senhas e parametros antes de usar em producao.
