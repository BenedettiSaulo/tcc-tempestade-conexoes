#!/bin/bash
# Gera pgbouncer.ini e proxysql.cnf a partir dos .template, substituindo
# ${DB_HOST}/${DB_PORT} pelos valores do .env. Rode de novo sempre que
# mudar o IP da VM01 no .env.
set -euo pipefail
cd "$(dirname "$0")"

if [[ ! -f .env ]]; then
  echo "ERRO: crie um .env nesta pasta (copie de .env.example) antes de rodar." >&2
  exit 1
fi
set -a; source .env; set +a

command -v envsubst >/dev/null 2>&1 || { echo "ERRO: instale 'gettext-base' (apt install -y gettext-base) para ter o envsubst." >&2; exit 1; }

envsubst '${DB_HOST} ${DB_PORT}' < pgbouncer/pgbouncer.ini.template > pgbouncer/pgbouncer.ini
envsubst '${DB_HOST} ${DB_PORT}' < proxysql/proxysql.cnf.template > proxysql/proxysql.cnf

echo "Configs gerados com DB_HOST=${DB_HOST} DB_PORT=${DB_PORT}:"
echo "  - pgbouncer/pgbouncer.ini"
echo "  - proxysql/proxysql.cnf"
