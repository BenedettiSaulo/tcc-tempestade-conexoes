#!/bin/bash
# start-worker.sh - roda na vm04. Sobe o jmeter-server (RMI) para receber
# comandos do master (vm03). Deixe rodando num "screen"/"tmux"/systemd -
# se cair a sessão SSH sem isso, o worker morre junto.
set -euo pipefail

JMETER_HOME="/opt/jmeter"
MY_IP="${1:-$(hostname -I | awk '{print $1}')}"

echo "Subindo jmeter-server na vm05, anunciando IP ${MY_IP} para o master..."
"$JMETER_HOME/bin/jmeter-server" \
  -Djava.rmi.server.hostname="$MY_IP" \
  -Dserver_port=1099 \
  -Dserver.rmi.localport=50000 \
  -Dserver.rmi.ssl.disable=true
