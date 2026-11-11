#!/bin/bash
# monitor-hardware.sh - grava uma amostra de CPU/memória de cada container
# a cada 2s num CSV.
#
#   ./monitor-hardware.sh start <arquivo_saida.csv>   # coleta em background
#   ./monitor-hardware.sh stop                        # para a coleta
set -uo pipefail

PIDFILE="/tmp/monitor-hardware.pid"
LOGFILE="/tmp/monitor-hardware.log"
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

stop_collector() {
  if [[ -f "$PIDFILE" ]]; then
    kill "$(cat "$PIDFILE")" 2>/dev/null || true
    rm -f "$PIDFILE"
  fi
}

case "${1:-}" in
  start)
    outfile="${2:?Uso: monitor-hardware.sh start <arquivo_saida.csv>}"
    # Se sobrou uma coleta de uma rodada anterior (ex.: teste interrompido
    # com Ctrl+C), encerra ela em vez de falhar.
    stop_collector
    # "< /dev/null" é essencial: sem ele o processo em background herda a
    # entrada do SSH e a sessão remota nunca fecha - o orquestrador na vm03
    # ficava travado exatamente neste passo.
    nohup bash "$SELF" __loop "$outfile" < /dev/null > "$LOGFILE" 2>&1 &
    echo $! > "$PIDFILE"
    echo "Coletando para $outfile (pid $(cat "$PIDFILE"))"
    ;;
  stop)
    stop_collector
    echo "Coleta parada."
    ;;
  __loop)
    outfile="$2"
    echo "timestamp,container,cpu_pct,mem_uso,mem_pct,net_io,block_io" > "$outfile"
    while true; do
      ts="$(date +%Y-%m-%dT%H:%M:%S)"
      docker stats --no-stream --format "{{.Name}},{{.CPUPerc}},{{.MemUsage}},{{.MemPerc}},{{.NetIO}},{{.BlockIO}}" \
        | sed "s/^/${ts},/" >> "$outfile"
      sleep 2
    done
    ;;
  *)
    echo "Uso: $0 start <arquivo_saida.csv> | stop" >&2
    exit 1
    ;;
esac
