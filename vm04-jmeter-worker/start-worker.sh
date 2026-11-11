#!/bin/bash
# start-worker.sh - roda na vm04. Sobe o jmeter-server (RMI) para receber
# comandos do master (vm03). Deixe rodando num "screen"/"tmux"/systemd -
# se cair a sessão SSH sem isso, o worker morre junto.
set -euo pipefail

JMETER_HOME="/opt/jmeter"
MY_IP="${1:-$(hostname -I | awk '{print $1}')}"

echo "Subindo jmeter-server na vm04, anunciando IP ${MY_IP} para o master..."
"$JMETER_HOME/bin/jmeter-server" \
  -Dojp.connection.pool.maximumPoolSize=50 -Dojp.connection.pool.minimumIdle=10 -Dojp.connection.pool.connectionTimeout=10000 -Djava.rmi.server.hostname="$MY_IP" \
  -Dserver_port=1099 \
  -Dserver.rmi.localport=50000 \
  -Dserver.rmi.ssl.disable=true
