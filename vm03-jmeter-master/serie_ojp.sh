#!/bin/bash
# uso: ./serie_ojp.sh <nome_da_serie>
set -a; source servers.env; set +a
[[ -d reports ]] && { echo "ERRO: mova ou renomeie a pasta reports antes"; exit 1; }
for i in 1 2 3; do
  ./run-all-benchmarks-distributed.sh --rate 350 --duration 60 4
  stamp=$(ls -1t reports/ojp | head -1)
  ssh ${SSH_USER}@${PROXY_HOST} "docker logs -t tcc-ojp 2>&1" > reports/ojp/$stamp/ojp_container.log
  ssh ${SSH_USER}@${PROXY_HOST} "docker inspect tcc-ojp"     > reports/ojp/$stamp/ojp_inspect.json
  echo "== $1: execução $i em reports/ojp/$stamp"
done
mv reports "reports_$1"
