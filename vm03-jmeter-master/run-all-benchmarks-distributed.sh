#!/bin/bash
# ==============================================================================
# run-all-benchmarks-distributed.sh - roda na vm03 (orquestrador), SEM sudo.
#
# Para cada cenário:
#   1. recria o banco na vm01;
#   2. deixa de pé na vm02 SOMENTE o proxy do cenário (os outros ficam parados);
#   3. coleta CPU/memória na vm01 e na vm02;
#   4. dispara o JMeter distribuído em todos os workers;
#   5. guarda tudo em reports/<cenario>/<data_hora>/ e acrescenta uma linha
#      em reports/resumo_geral.csv.
#
# Uso:
#   ./run-all-benchmarks-distributed.sh                       # os 4 cenários
#   ./run-all-benchmarks-distributed.sh 1                     # só o baseline
#   ./run-all-benchmarks-distributed.sh --rate 600 --duration 120 1 2
#
# --rate é a taxa TOTAL (soma de todos os workers).
# ==============================================================================
set -euo pipefail
cd "$(dirname "$0")"

[[ -f servers.env ]] || { echo "ERRO: crie servers.env nesta pasta." >&2; exit 1; }
set -a; source servers.env; set +a

TARGET_RATE="${TARGET_RATE:-200}"
TEST_DURATION="${TEST_DURATION:-60}"
WARMUP_SECONDS="${WARMUP_SECONDS:-20}"   # 0 desliga o aquecimento
JMX_FILE="tcc_bench.jmx"
REPORTS_DIR="reports"
RESUMO_CSV="${REPORTS_DIR}/resumo_geral.csv"
RESUMO_HEADER="data_hora,cenario,workers,rate_total,rate_por_worker,duracao_s,amostras,erros,erro_pct,media_ms,p90_ms,p95_ms,p99_ms,max_ms,throughput_req_s,pasta"
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=5"
ALL_PROXIES="pgbouncer haproxy proxysql open-j-proxy"

declare -A SCENARIO_NAME=(     [1]="baseline" [2]="pgbouncer_haproxy" [3]="proxysql" [4]="ojp" )
declare -A SCENARIO_SERVICES=( [1]=""         [2]="pgbouncer haproxy" [3]="proxysql" [4]="open-j-proxy" )
declare -A SCENARIO_PORTS=(    [1]=""         [2]="6432 6433"         [3]="6033"     [4]="1059" )

if [[ -x /opt/jmeter/bin/jmeter ]]; then JMETER_BIN="/opt/jmeter/bin/jmeter"; else JMETER_BIN="jmeter"; fi

SCENARIOS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --rate) TARGET_RATE="$2"; shift 2 ;;
    --duration) TEST_DURATION="$2"; shift 2 ;;
    --warmup) WARMUP_SECONDS="$2"; shift 2 ;;
    1|2|3|4) SCENARIOS+=("$1"); shift ;;
    *) echo "Argumento desconhecido: $1" >&2; exit 1 ;;
  esac
done
[[ ${#SCENARIOS[@]} -eq 0 ]] && SCENARIOS=(1 2 3 4)

# ---------- workers ----------
# servers.env: JMETER_WORKER_HOSTS=ip1,ip2   (o antigo JMETER_WORKER_HOST ainda vale)
WORKERS_CSV="$(echo "${JMETER_WORKER_HOSTS:-${JMETER_WORKER_HOST:-}}" | tr -d ' ')"
[[ -n "$WORKERS_CSV" ]] || { echo "ERRO: defina JMETER_WORKER_HOSTS=ip1,ip2 no servers.env." >&2; exit 1; }
IFS=',' read -r -a WORKERS <<< "$WORKERS_CSV"
N_WORKERS=${#WORKERS[@]}

# No JMeter distribuído CADA worker executa o plano inteiro. Para a taxa
# pedida ser a taxa total, cada worker recebe a sua fatia.
RATE_PER_WORKER=$(( (TARGET_RATE + N_WORKERS - 1) / N_WORKERS ))
RATE_TOTAL=$(( RATE_PER_WORKER * N_WORKERS ))
# Aquecimento: 25% da taxa (mínimo 2 req/s por worker), resultado descartado.
WARMUP_PER_WORKER=$(( RATE_PER_WORKER / 4 )); [[ $WARMUP_PER_WORKER -lt 2 ]] && WARMUP_PER_WORKER=2

# IP desta VM visto pelos workers (eles conectam de volta para entregar resultados).
MASTER_HOST="${JMETER_MASTER_HOST:-$(ip -4 route get "${WORKERS[0]}" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)}"
[[ -n "$MASTER_HOST" ]] || MASTER_HOST="$(hostname -I | awk '{print $1}')"

JMETER_TIMEOUT=$(( TEST_DURATION + 10 + 300 ))

ssh_db()    { ssh $SSH_OPTS "${SSH_USER}@${DB_HOST}"    "cd ${DB_REMOTE_DIR} && $*"; }
ssh_proxy() { ssh $SSH_OPTS "${SSH_USER}@${PROXY_HOST}" "cd ${PROXY_REMOTE_DIR} && $*"; }
port_open() { timeout 3 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; }
wait_for_port() {
  local host="$1" port="$2" tries=40
  until port_open "$host" "$port"; do
    tries=$((tries - 1))
    [[ $tries -le 0 ]] && { echo "   aviso: ${host}:${port} não respondeu a tempo"; return 0; }
    sleep 1
  done
}

wait_workers() {
  local w tries
  for w in "${WORKERS[@]}"; do
    tries=90
    until port_open "$w" 1099 && port_open "$w" 50000; do
      tries=$((tries - 1))
      if [[ $tries -le 0 ]]; then
        echo "!! O worker ${w} não voltou depois da rodada anterior."
        echo "   Ele precisa reiniciar sozinho: no systemd use Restart=always; em primeiro plano use"
        echo "   while true; do ./start-worker.sh ${w}; sleep 2; done"
        return 1
      fi
      sleep 1
    done
  done
}

# Depois de um teste com -X o worker demora alguns segundos para encerrar.
# Se checarmos as portas cedo demais, achamos o processo ANTIGO ainda de pé e
# o master tenta configurar um worker que está morrendo ("Failed to configure").
wait_workers_restart() {
  local w tries
  for w in "${WORKERS[@]}"; do
    tries=30
    while port_open "$w" 1099 && [[ $tries -gt 0 ]]; do sleep 1; tries=$((tries - 1)); done
  done
  wait_workers || return 1
  sleep 5   # o registro RMI abre antes de o motor do JMeter estar pronto
}

# Roda o JMeter; se os workers não aceitarem a configuração, espera e tenta
# mais uma vez antes de desistir.
run_jmeter() {
  local console="$1"; shift
  local rc=0
  "$@" > "$console" 2>&1 || rc=$?
  local tentativa=1
  while [[ $rc -ne 0 ]] && grep -q "could not be configured" "$console" && [[ $tentativa -le 6 ]]; do
    echo "   Workers ainda não estavam prontos; tentativa $((tentativa + 1)) em 15s..."
    sleep 15
    wait_workers || return 1
    rc=0; "$@" > "$console" 2>&1 || rc=$?
    tentativa=$((tentativa + 1))
  done
  return $rc
}

# ---------- organização da pasta reports ----------
mkdir -p "$REPORTS_DIR"
# arquivos soltos do formato antigo vão para reports/_antigos (nada é apagado)
shopt -s nullglob
soltos=( "$REPORTS_DIR"/*.jtl "$REPORTS_DIR"/*.log "$REPORTS_DIR"/db_*.csv "$REPORTS_DIR"/proxy_*.csv "$REPORTS_DIR"/html_* )
shopt -u nullglob
if [[ -f "$RESUMO_CSV" && "$(head -1 "$RESUMO_CSV")" != "$RESUMO_HEADER" ]]; then soltos+=( "$RESUMO_CSV" ); fi
if [[ ${#soltos[@]} -gt 0 ]]; then
  mkdir -p "$REPORTS_DIR/_antigos"
  mv "${soltos[@]}" "$REPORTS_DIR/_antigos/"
  echo "Movi ${#soltos[@]} arquivo(s) do formato antigo para ${REPORTS_DIR}/_antigos/"
fi
[[ -f "$RESUMO_CSV" ]] || echo "$RESUMO_HEADER" > "$RESUMO_CSV"

# ---------- checagens antes de começar ----------
JMETER_VERSION="$("$JMETER_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true)"
echo "Orquestrador: ${MASTER_HOST} | workers (${N_WORKERS}): ${WORKERS_CSV} | banco: ${DB_HOST} | proxies: ${PROXY_HOST}"
echo "Carga: ${RATE_TOTAL} req/s no total = ${RATE_PER_WORKER} req/s em cada worker, platô de ${TEST_DURATION}s | JMeter ${JMETER_VERSION:-?}"
falhou=0
for w in "${WORKERS[@]}"; do
  port_open "$w" 1099  || { echo "ERRO: worker ${w}:1099 não responde - o jmeter-server está rodando nele?"; falhou=1; }
  port_open "$w" 50000 || { echo "ERRO: worker ${w}:50000 não responde - confira -Dserver.rmi.localport=50000 nele."; falhou=1; }
done
ssh $SSH_OPTS "${SSH_USER}@${DB_HOST}" true    2>/dev/null || { echo "ERRO: SSH sem senha para ${SSH_USER}@${DB_HOST} (vm01) falhou."; falhou=1; }
ssh $SSH_OPTS "${SSH_USER}@${PROXY_HOST}" true 2>/dev/null || { echo "ERRO: SSH sem senha para ${SSH_USER}@${PROXY_HOST} (vm02) falhou."; falhou=1; }
[[ $falhou -eq 0 ]] || exit 1

run_one_scenario() {
  local scenario="$1" nome="${SCENARIO_NAME[$1]}" services="${SCENARIO_SERVICES[$1]}"
  local stamp; stamp="$(date +%Y-%m-%d_%H-%M-%S)"
  local run_dir="${REPORTS_DIR}/${nome}/${stamp}"
  local remote_csv="hw_${nome}_${stamp}.csv"
  mkdir -p "$run_dir"

  echo ""
  echo "=============================================================="
  echo " Cenário ${scenario} (${nome}) - ${RATE_TOTAL} req/s por ${TEST_DURATION}s - ${N_WORKERS} worker(s)"
  echo " Pasta: ${run_dir}"
  echo "=============================================================="

  echo "-> [vm01] Recriando o banco..."
  ssh_db "./reset-env.sh" > "${run_dir}/preparacao.log" 2>&1 || { cat "${run_dir}/preparacao.log"; echo "!! Falha ao recriar o banco."; return 0; }

  echo "-> [vm02] Isolando o cenário: parando todos os proxies e subindo só: ${services:-nenhum}"
  local cmd="docker compose stop ${ALL_PROXIES} && docker compose rm -f ${ALL_PROXIES}"
  [[ -n "$services" ]] && cmd="${cmd} && docker compose up -d ${services}"
  ssh_proxy "$cmd" >> "${run_dir}/preparacao.log" 2>&1 || { tail -n 15 "${run_dir}/preparacao.log"; echo "!! Falha ao preparar os proxies."; return 0; }

  wait_for_port "$DB_HOST" 5432
  for p in ${SCENARIO_PORTS[$scenario]}; do wait_for_port "$PROXY_HOST" "$p"; done
  sleep 5
  local ativos; ativos="$(ssh_proxy "docker ps --format '{{.Names}}'" 2>/dev/null | sort | paste -sd' ' || true)"
  echo "   Containers ativos na vm02: ${ativos:-nenhum}"

  cat > "${run_dir}/info.txt" <<INFO
cenario=${nome}
data_hora=${stamp}
rate_total_req_s=${RATE_TOTAL}
rate_por_worker_req_s=${RATE_PER_WORKER}
duracao_plato_s=${TEST_DURATION}
workers=${WORKERS_CSV}
orquestrador=${MASTER_HOST}
banco=${DB_HOST}
proxies=${PROXY_HOST}
containers_ativos_vm02=${ativos:-nenhum}
jmeter=${JMETER_VERSION:-?}
aquecimento_s=${WARMUP_SECONDS}
aquecimento_req_s_por_worker=${WARMUP_PER_WORKER}
INFO

  # Cada rodada termina encerrando os workers (-X); eles precisam voltar
  # sozinhos (systemd Restart=always ou laço no start-worker). JVM nova a cada
  # rodada = mesmo estado inicial para todos os cenários, e o driver do OJP
  # não carrega sessão de um servidor que já foi recriado.
  wait_workers || { echo "   Bateria interrompida: sem todos os workers não há como medir."; exit 1; }

  # Aquecimento (mesmo procedimento em TODOS os cenários): os proxies acabaram
  # de ser recriados e abrem conexões com o banco sob demanda. Sem isso, os
  # primeiros segundos medem o arranque a frio, não o regime de operação.
  # O resultado fica em aquecimento/ e não entra no resumo nem no hardware.
  if [[ "$WARMUP_SECONDS" -gt 0 ]]; then
    echo "-> Aquecimento: ${WARMUP_PER_WORKER} req/s por worker durante ${WARMUP_SECONDS}s (descartado)..."
    mkdir -p "${run_dir}/aquecimento"
    local wrc=0
    run_jmeter "${run_dir}/aquecimento/console.log" \
    timeout $(( WARMUP_SECONDS + 10 + 120 )) "$JMETER_BIN" -n -t "$JMX_FILE" \
      -R "$WORKERS_CSV" \
      -Djava.rmi.server.hostname="$MASTER_HOST" \
      -Dserver.rmi.ssl.disable=true \
      -GTARGET_SCENARIO="$scenario" \
      -GTARGET_RATE="$WARMUP_PER_WORKER" \
      -GTEST_DURATION="$WARMUP_SECONDS" \
      -GDB_HOST="$DB_HOST" \
      -GPROXY_HOST="$PROXY_HOST" \
      -j "${run_dir}/aquecimento/jmeter.log" \
      -l "${run_dir}/aquecimento/resultados.jtl" || wrc=$?
    if [[ $wrc -ne 0 ]]; then
      echo "!! O aquecimento falhou (código ${wrc}). Últimas linhas:"; tail -n 15 "${run_dir}/aquecimento/console.log" | sed 's/^/     /'
      return 0
    fi
    local werr; werr=$(awk 'NR>1 && /,false(,|$)/ {n++} END {print n+0}' "${run_dir}/aquecimento/resultados.jtl")
    echo "   Aquecimento concluído ($(( $(wc -l < "${run_dir}/aquecimento/resultados.jtl") - 1 )) requisições, ${werr} com erro)."
    # Sem -X no aquecimento: a JVM dos workers (driver, conexões gRPC, JIT)
    # continua aquecida para a rodada medida. Os workers só são reiniciados
    # ao fim da rodada medida, antes do próximo cenário recriar o proxy.
    sleep 3
    wait_workers || { echo "   Bateria interrompida: sem todos os workers não há como medir."; exit 1; }
  fi

  echo "-> Iniciando coleta de CPU/memória em vm01 e vm02..."
  ssh_db    "mkdir -p reports && ./monitor-hardware.sh start reports/${remote_csv}" >/dev/null
  ssh_proxy "mkdir -p reports && ./monitor-hardware.sh start reports/${remote_csv}" >/dev/null

  echo "-> Rodando JMeter (uns $(( TEST_DURATION + 30 ))s). Para acompanhar: tail -f ${run_dir}/console.log"
  local rc=0
  run_jmeter "${run_dir}/console.log" \
  timeout "$JMETER_TIMEOUT" "$JMETER_BIN" -n -t "$JMX_FILE" \
    -R "$WORKERS_CSV" \
    -X \
    -Djava.rmi.server.hostname="$MASTER_HOST" \
    -Dserver.rmi.ssl.disable=true \
    -GTARGET_SCENARIO="$scenario" \
    -GTARGET_RATE="$RATE_PER_WORKER" \
    -GTEST_DURATION="$TEST_DURATION" \
    -GDB_HOST="$DB_HOST" \
    -GPROXY_HOST="$PROXY_HOST" \
    -j "${run_dir}/jmeter.log" \
    -l "${run_dir}/resultados.jtl" \
    -e -o "${run_dir}/dashboard" || rc=$?

  echo "-> Parando coleta e trazendo os dados de hardware..."
  ( wait_workers_restart >/dev/null 2>&1 ) &   # workers reiniciando em paralelo à cópia dos dados
  local espera_pid=$!
  ssh_db    "./monitor-hardware.sh stop" >/dev/null || true
  ssh_proxy "./monitor-hardware.sh stop" >/dev/null || true
  scp -q $SSH_OPTS "${SSH_USER}@${DB_HOST}:${DB_REMOTE_DIR}/reports/${remote_csv}"       "${run_dir}/hardware_vm01_banco.csv"   2>/dev/null \
    && ssh_db "rm -f reports/${remote_csv}" || echo "   aviso: não consegui copiar o hardware da vm01"
  scp -q $SSH_OPTS "${SSH_USER}@${PROXY_HOST}:${PROXY_REMOTE_DIR}/reports/${remote_csv}" "${run_dir}/hardware_vm02_proxies.csv" 2>/dev/null \
    && ssh_proxy "rm -f reports/${remote_csv}" || echo "   aviso: não consegui copiar o hardware da vm02"

  wait "$espera_pid" 2>/dev/null || true
  if [[ $rc -ne 0 ]]; then
    echo ""
    if [[ $rc -eq 124 ]]; then
      echo "!! O JMeter não terminou em ${JMETER_TIMEOUT}s e foi interrompido. Reinicie o jmeter-server nos workers antes de tentar de novo."
    else
      echo "!! O JMeter terminou com erro (código ${rc})."
    fi
    echo "   Últimas linhas de ${run_dir}/console.log:"
    tail -n 20 "${run_dir}/console.log" | sed 's/^/     /'
    return 0
  fi

  python3 - "$run_dir" "$stamp" "$nome" "$N_WORKERS" "$RATE_TOTAL" "$RATE_PER_WORKER" "$TEST_DURATION" "$RESUMO_CSV" <<'PYEOF' | tee "${run_dir}/resumo.txt"
import csv, json, os, sys, collections
run_dir, stamp, nome, nw, rate_total, rate_w, duration, resumo_csv = sys.argv[1:9]

stats = os.path.join(run_dir, "dashboard", "statistics.json")
if os.path.exists(stats):
    with open(stats, encoding="utf-8") as f:
        data = json.load(f)
    t = data.get("Total") or next(iter(data.values()), {})
    r = lambda k, nd: round(t[k], nd) if k in t else "N/A"
    row = [stamp, nome, nw, rate_total, rate_w, duration,
           t.get("sampleCount", "N/A"), t.get("errorCount", "N/A"), r("errorPct", 3),
           r("meanResTime", 1), r("pct1ResTime", 1), r("pct2ResTime", 1), r("pct3ResTime", 1),
           r("maxResTime", 1), r("throughput", 2), run_dir]
    with open(resumo_csv, "a", newline="", encoding="utf-8") as f:
        csv.writer(f).writerow(row)
    print(f"   Requisições: {row[6]} | erros: {row[7]} ({row[8]}%) | vazão: {row[14]} req/s")
    print(f"   Latência (ms): média {row[9]} | p90 {row[10]} | p95 {row[11]} | p99 {row[12]} | máx {row[13]}")
else:
    print("   aviso: dashboard/statistics.json não foi gerado - nada acrescentado ao resumo_geral.csv")

# principais mensagens de erro (é aqui que aparece a tempestade de conexões)
jtl = os.path.join(run_dir, "resultados.jtl")
if os.path.exists(jtl):
    erros = collections.Counter()
    with open(jtl, encoding="utf-8", errors="replace", newline="") as f:
        for linha in csv.DictReader(f):
            if linha.get("success") == "false":
                erros[" ".join((linha.get("responseMessage") or "").split())[:110]] += 1
    for msg, n in erros.most_common(3):
        print(f"   Erro x{n}: {msg}")

# pico de CPU e de memória por container
def mem_mib(txt):
    v = txt.split("/")[0].strip()
    for suf, mult in (("GiB", 1024), ("MiB", 1), ("KiB", 1 / 1024), ("B", 1 / 1048576)):
        if v.endswith(suf):
            try: return float(v[:-len(suf)]) * mult
            except ValueError: return 0.0
    return 0.0
for arq, rotulo in (("hardware_vm01_banco.csv", "vm01"), ("hardware_vm02_proxies.csv", "vm02")):
    caminho = os.path.join(run_dir, arq)
    if not os.path.exists(caminho):
        continue
    cpu, mem = collections.defaultdict(float), collections.defaultdict(float)
    with open(caminho, encoding="utf-8", errors="replace", newline="") as f:
        for l in csv.DictReader(f):
            try: cpu[l["container"]] = max(cpu[l["container"]], float(l["cpu_pct"].rstrip("%")))
            except (ValueError, KeyError, AttributeError): continue
            mem[l["container"]] = max(mem[l["container"]], mem_mib(l.get("mem_uso") or ""))
    for c in sorted(cpu):
        print(f"   Pico {rotulo} {c}: CPU {cpu[c]:.0f}% | memória {mem[c]:.0f} MiB")
PYEOF
}

for s in "${SCENARIOS[@]}"; do
  run_one_scenario "$s"
done

echo ""
echo "=============================================================="
echo " Fim. Comparativo de todas as rodadas: ${RESUMO_CSV}"
echo "=============================================================="
