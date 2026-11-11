#!/bin/bash
# pg-sampler.sh - amostra o PostgreSQL 1x/s com UMA sessao psql persistente (\watch).
# Uso (na vm01, pasta vm01-db):
#   ./pg-sampler.sh start reports/arquivo.csv
#   ./pg-sampler.sh stop
# Colunas: epoch_ms (relogio do banco), conexoes de clientes, ativas, idle in transaction,
#          esperando lock, xact_commit, xact_rollback.
# A propria sessao do amostrador (application_name=pgsampler) e excluida da contagem,
# mas ocupa 1 das 100 conexoes.
set -uo pipefail
PIDFILE=/tmp/pg-sampler.pid
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

stop_it() {
  [[ -f "$PIDFILE" ]] && { pkill -P "$(cat "$PIDFILE")" 2>/dev/null; kill "$(cat "$PIDFILE")" 2>/dev/null; rm -f "$PIDFILE"; }
  pkill -f "pg-sampler.sh __loop" 2>/dev/null
  docker exec tcc-postgres psql -U postgres -d pagila -qtAc \
    "select pg_terminate_backend(pid) from pg_stat_activity where application_name='pgsampler'" >/dev/null 2>&1 || true
}

case "${1:-}" in
  start)
    out="${2:?Uso: pg-sampler.sh start <arquivo.csv>}"
    stop_it
    mkdir -p "$(dirname "$out")"
    nohup bash "$SELF" __loop "$out" < /dev/null > /tmp/pg-sampler.log 2>&1 &
    echo $! > "$PIDFILE"
    echo "pg-sampler -> $out (pid $(cat "$PIDFILE"))"
    ;;
  stop) stop_it; echo "pg-sampler parado." ;;
  __loop)
    out="$2"   
    echo "epoch_ms,clientes,ativas,idle_in_tx,esperando_lock,xact_commit,xact_rollback" > "$out"
    SQL="select (extract(epoch from clock_timestamp())*1000)::bigint,
      count(*) filter (where backend_type='client backend' and application_name<>'pgsampler'),
      count(*) filter (where backend_type='client backend' and application_name<>'pgsampler' and state='active'),
      count(*) filter (where backend_type='client backend' and application_name<>'pgsampler' and state='idle in transaction'),
      count(*) filter (where backend_type='client backend' and application_name<>'pgsampler' and wait_event_type='Lock'),
      (select xact_commit from pg_stat_database where datname='pagila'),
      (select xact_rollback from pg_stat_database where datname='pagila')
      from pg_stat_activity"
    # o container pode ser recriado/ainda subindo: tenta de novo ate o stop
    while true; do
      printf '%s;\n\\watch 1\n' "$SQL" | docker exec -i -e PGAPPNAME=pgsampler tcc-postgres \
        psql -U postgres -d pagila -qtA -F, 2>>"$out.err" | grep --line-buffered -E '^[0-9]{13},' >> "$out"
      sleep 1
    done
    ;;
  *) echo "Uso: $0 start <arquivo.csv> | stop" >&2; exit 1 ;;
esac
