#!/bin/bash
# ==============================================================================
# run-retry-experiment.sh - ETAPA 2 (vm03). Pico de carga com retry/backoff.
#
# Perfil (por execucao): aquecimento 20s a 25% da taxa base (descartado, plano
# antigo tcc_bench.jmx) -> rampa 5s -> PRE_SEC na taxa base -> pico SPIKE_SEC
# -> POST_SEC na taxa base (recuperacao) -> rampa de descida 5s.
# Cada requisicao logica tem ate MAX_ATTEMPTS tentativas com backoff exponencial.
#
# Cenarios INTERCALADOS: k blocos; em cada bloco os 4 cenarios rodam numa ordem
# diferente (quadrado latino), para que variacoes do ambiente nao se concentrem
# em um cenario so.
#
# Uso:
#   ./run-retry-experiment.sh                       # 3 blocos x 4 cenarios (~50 min)
#   ./run-retry-experiment.sh --reps 1 4            # teste rapido: 1 bloco so do OJP
#   ./run-retry-experiment.sh --base 160 --spike 400 --pre 30 --spike-sec 30 --post 90
# As taxas sao TOTAIS (somadas nos workers).
# ==============================================================================
set -euo pipefail
cd "$(dirname "$0")"
[[ -f servers.env ]] || { echo "ERRO: crie servers.env nesta pasta." >&2; exit 1; }
set -a; source servers.env; set +a

BASE_RATE=160; SPIKE_RATE=400; PRE_SEC=30; SPIKE_SEC=30; POST_SEC=90; RAMP_SEC=2
MAX_ATTEMPTS=4; BACKOFF_BASE_MS=100; BACKOFF_CAP_MS=2000; DEADLINE_MS=15000
WARMUP_SECONDS=20; REPS=3; COOLDOWN=30
JMX_WARM="tcc_bench.jmx"; JMX_MAIN="tcc_retry.jmx"
OUT_DIR="reports_retry"
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=5"
ALL_PROXIES="pgbouncer haproxy proxysql open-j-proxy"
declare -A NAME=(     [1]=baseline [2]=pgbouncer_haproxy [3]=proxysql [4]=ojp )
declare -A SERVICES=( [1]=""       [2]="pgbouncer haproxy" [3]="proxysql" [4]="open-j-proxy" )
declare -A PORTS=(    [1]=""       [2]="6432 6433"         [3]="6033"     [4]="1059" )
# quadrado latino: cada cenario aparece em posicoes diferentes nos 3 blocos
ORDERS=( "1 2 3 4" "2 4 1 3" "3 1 4 2" )

ONLY=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base) BASE_RATE="$2"; shift 2 ;;      --spike) SPIKE_RATE="$2"; shift 2 ;;
    --pre) PRE_SEC="$2"; shift 2 ;;         --spike-sec) SPIKE_SEC="$2"; shift 2 ;;
    --post) POST_SEC="$2"; shift 2 ;;       --reps) REPS="$2"; shift 2 ;;
    --attempts) MAX_ATTEMPTS="$2"; shift 2 ;; --backoff-base) BACKOFF_BASE_MS="$2"; shift 2 ;; --cooldown) COOLDOWN="$2"; shift 2 ;;
    1|2|3|4) ONLY+=("$1"); shift ;;
    *) echo "Argumento desconhecido: $1" >&2; exit 1 ;;
  esac
done

if [[ -x /opt/jmeter/bin/jmeter ]]; then JMETER_BIN=/opt/jmeter/bin/jmeter; else JMETER_BIN=jmeter; fi
WORKERS_CSV="$(echo "${JMETER_WORKER_HOSTS:-${JMETER_WORKER_HOST:-}}" | tr -d ' ')"
[[ -n "$WORKERS_CSV" ]] || { echo "ERRO: defina JMETER_WORKER_HOSTS." >&2; exit 1; }
IFS=',' read -r -a WORKERS <<< "$WORKERS_CSV"; NW=${#WORKERS[@]}
per_w() { echo $(( ($1 + NW - 1) / NW )); }
PRE_W=$(per_w "$BASE_RATE"); SPIKE_W=$(per_w "$SPIKE_RATE")
WARM_W=$(( PRE_W / 4 )); [[ $WARM_W -lt 2 ]] && WARM_W=2
MASTER_HOST="${JMETER_MASTER_HOST:-$(ip -4 route get "${WORKERS[0]}" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)}"
[[ -n "$MASTER_HOST" ]] || MASTER_HOST="$(hostname -I | awk '{print $1}')"
TOTAL_S=$(( 5 + PRE_SEC + RAMP_SEC + SPIKE_SEC + RAMP_SEC + POST_SEC + 5 ))
JMETER_TIMEOUT=$(( TOTAL_S + 300 ))

ssh_db()    { ssh $SSH_OPTS "${SSH_USER}@${DB_HOST}"    "cd ${DB_REMOTE_DIR} && $*"; }
ssh_proxy() { ssh $SSH_OPTS "${SSH_USER}@${PROXY_HOST}" "cd ${PROXY_REMOTE_DIR} && $*"; }
port_open() { timeout 3 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; }
wait_for_port() { local t=40; until port_open "$1" "$2"; do t=$((t-1)); [[ $t -le 0 ]] && { echo "   aviso: $1:$2 nao respondeu"; return 0; }; sleep 1; done; }
wait_workers() {
  local w t
  for w in "${WORKERS[@]}"; do
    t=90; until port_open "$w" 1099 && port_open "$w" 50000; do
      t=$((t-1)); [[ $t -le 0 ]] && { echo "!! worker $w nao voltou"; return 1; }; sleep 1; done
  done
}
wait_workers_restart() {
  local w t
  for w in "${WORKERS[@]}"; do t=30; while port_open "$w" 1099 && [[ $t -gt 0 ]]; do sleep 1; t=$((t-1)); done; done
  wait_workers || return 1; sleep 5
}
run_jmeter() { local console="$1"; shift; local rc=0; "$@" > "$console" 2>&1 || rc=$?
  local n=1; while [[ $rc -ne 0 ]] && grep -q "could not be configured" "$console" && [[ $n -le 6 ]]; do
    echo "   workers nao prontos; nova tentativa em 15s"; sleep 15; wait_workers || return 1
    rc=0; "$@" > "$console" 2>&1 || rc=$?; n=$((n+1)); done; return $rc; }

mkdir -p "$OUT_DIR"
for w in "${WORKERS[@]}"; do port_open "$w" 1099 || { echo "ERRO: worker $w:1099 fora"; exit 1; }; done
ssh $SSH_OPTS "${SSH_USER}@${DB_HOST}" true    || { echo "ERRO ssh vm01"; exit 1; }
ssh $SSH_OPTS "${SSH_USER}@${PROXY_HOST}" true || { echo "ERRO ssh vm02"; exit 1; }
ssh_db "test -x ./pg-sampler.sh" 2>/dev/null || echo "AVISO: pg-sampler.sh ausente/sem permissao na vm01; a coleta do banco sera pulada."

run_one() {
  local sc="$1" rep="$2" nome="${NAME[$1]}" svc="${SERVICES[$1]}"
  local stamp; stamp="$(date +%Y-%m-%d_%H-%M-%S)"
  local d="${OUT_DIR}/${nome}/${stamp}"; local rcsv="hw_${nome}_${stamp}.csv"; local pcsv="pg_${nome}_${stamp}.csv"
  mkdir -p "$d"
  echo ""; echo "=== bloco ${rep}/${REPS} | cenario ${sc} (${nome}) | base ${BASE_RATE} -> pico ${SPIKE_RATE} req/s | ${d}"
  cat > "$d/info.txt" <<INFO
cenario=${nome}
bloco=${rep}
data_hora=${stamp}
base_total=${BASE_RATE}
pico_total=${SPIKE_RATE}
base_por_worker=${PRE_W}
pico_por_worker=${SPIKE_W}
pre_s=${PRE_SEC}
pico_s=${SPIKE_SEC}
pos_s=${POST_SEC}
rampa_s=${RAMP_SEC}
max_tentativas=${MAX_ATTEMPTS}
backoff_base_ms=${BACKOFF_BASE_MS}
backoff_teto_ms=${BACKOFF_CAP_MS}
prazo_ms=${DEADLINE_MS}
workers=${WORKERS_CSV}
INFO
  echo "-> recriando banco"
  ssh_db "./reset-env.sh" > "$d/preparacao.log" 2>&1 || { tail -5 "$d/preparacao.log"; echo "!! falha no reset"; return 0; }
  echo "-> isolando proxy: ${svc:-nenhum}"
  local cmd="docker compose stop ${ALL_PROXIES} && docker compose rm -f ${ALL_PROXIES}"
  [[ -n "$svc" ]] && cmd="${cmd} && docker compose up -d ${svc}"
  ssh_proxy "$cmd" >> "$d/preparacao.log" 2>&1 || { echo "!! falha nos proxies"; return 0; }
  wait_for_port "$DB_HOST" 5432; for p in ${PORTS[$sc]}; do wait_for_port "$PROXY_HOST" "$p"; done
  sleep 5
  wait_workers || exit 1

  echo "-> aquecimento ${WARMUP_SECONDS}s a ${WARM_W} req/s/worker (descartado)"
  mkdir -p "$d/aquecimento"
  run_jmeter "$d/aquecimento/console.log" timeout $((WARMUP_SECONDS+130)) "$JMETER_BIN" -n -t "$JMX_WARM" -R "$WORKERS_CSV" \
    -Djava.rmi.server.hostname="$MASTER_HOST" -Dserver.rmi.ssl.disable=true \
    -GTARGET_SCENARIO="$sc" -GTARGET_RATE="$WARM_W" -GTEST_DURATION="$WARMUP_SECONDS" \
    -GDB_HOST="$DB_HOST" -GPROXY_HOST="$PROXY_HOST" \
    -j "$d/aquecimento/jmeter.log" -l "$d/aquecimento/resultados.jtl" || { echo "!! aquecimento falhou"; return 0; }
  sleep 3; wait_workers || exit 1

  echo "-> iniciando coletores (hardware vm01/vm02, banco vm01)"
  ssh_db    "mkdir -p reports && ./monitor-hardware.sh start reports/${rcsv}" >/dev/null
  ssh_proxy "mkdir -p reports && ./monitor-hardware.sh start reports/${rcsv}" >/dev/null
  ssh_db    "./pg-sampler.sh start reports/${pcsv}" >/dev/null 2>&1 || echo "   aviso: pg-sampler nao iniciou"
  sleep 3

  echo "-> pico de carga (~${TOTAL_S}s)"
  local rc=0
  run_jmeter "$d/console.log" timeout "$JMETER_TIMEOUT" "$JMETER_BIN" -n -t "$JMX_MAIN" -R "$WORKERS_CSV" -X \
    -Djava.rmi.server.hostname="$MASTER_HOST" -Dserver.rmi.ssl.disable=true \
    -GTARGET_SCENARIO="$sc" -GPRE_RATE="$PRE_W" -GSPIKE_RATE="$SPIKE_W" \
    -GPRE_SEC="$PRE_SEC" -GSPIKE_SEC="$SPIKE_SEC" -GPOST_SEC="$POST_SEC" -GRAMP_SEC="$RAMP_SEC" \
    -GMAX_ATTEMPTS="$MAX_ATTEMPTS" -GBACKOFF_BASE_MS="$BACKOFF_BASE_MS" -GBACKOFF_CAP_MS="$BACKOFF_CAP_MS" -GDEADLINE_MS="$DEADLINE_MS" \
    -GDB_HOST="$DB_HOST" -GPROXY_HOST="$PROXY_HOST" \
    -j "$d/jmeter.log" -l "$d/resultados.jtl" || rc=$?

  echo "-> parando coletores e copiando dados"
  ( wait_workers_restart >/dev/null 2>&1 ) & local wp=$!
  ssh_db "./pg-sampler.sh stop" >/dev/null 2>&1 || true
  ssh_db "./monitor-hardware.sh stop" >/dev/null || true
  ssh_proxy "./monitor-hardware.sh stop" >/dev/null || true
  scp -q $SSH_OPTS "${SSH_USER}@${DB_HOST}:${DB_REMOTE_DIR}/reports/${rcsv}" "$d/hardware_vm01_banco.csv" 2>/dev/null && ssh_db "rm -f reports/${rcsv}" || echo "   aviso: sem hardware vm01"
  scp -q $SSH_OPTS "${SSH_USER}@${PROXY_HOST}:${PROXY_REMOTE_DIR}/reports/${rcsv}" "$d/hardware_vm02_proxies.csv" 2>/dev/null && ssh_proxy "rm -f reports/${rcsv}" || echo "   aviso: sem hardware vm02"
  scp -q $SSH_OPTS "${SSH_USER}@${DB_HOST}:${DB_REMOTE_DIR}/reports/${pcsv}" "$d/pg_amostras.csv" 2>/dev/null && ssh_db "rm -f reports/${pcsv}" || echo "   aviso: sem amostras do banco"
  # o log do OJP some no proximo 'rm -f': guarda agora
  if [[ "$sc" == "4" ]]; then
    ssh $SSH_OPTS "${SSH_USER}@${PROXY_HOST}" "docker logs -t tcc-ojp 2>&1 | gzip" > "$d/ojp_container.log.gz" 2>/dev/null || echo "   aviso: sem log do OJP"
  fi
  wait "$wp" 2>/dev/null || true
  [[ $rc -ne 0 ]] && { echo "!! JMeter terminou com codigo $rc (ver $d/console.log)"; tail -n 15 "$d/console.log" | sed 's/^/     /'; return 0; }
  local n f; n=$(( $(wc -l < "$d/resultados.jtl") - 1 )); f=$(awk -F, 'NR>1 && $8=="false"{c++} END{print c+0}' "$d/resultados.jtl")
  echo "   requisicoes logicas: ${n} | falhas finais: ${f}"
}

for ((rep=1; rep<=REPS; rep++)); do
  order="${ORDERS[$(( (rep-1) % ${#ORDERS[@]} ))]}"
  [[ ${#ONLY[@]} -gt 0 ]] && order="${ONLY[*]}"
  for sc in $order; do
    run_one "$sc" "$rep"
    echo "   pausa de ${COOLDOWN}s"; sleep "$COOLDOWN"
  done
done
echo ""; echo "Fim. Dados em ${OUT_DIR}/"
