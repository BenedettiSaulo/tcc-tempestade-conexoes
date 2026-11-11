#!/bin/bash
# install-jmeter.sh - instala Java, o Apache JMeter e o plugin "Custom
# Thread Groups" (necessário para o OpenModelThreadGroup do tcc_bench.jmx).
# Rode IGUAL na vm03 (master) e na vm04 (worker) - o JMeter exige que
# todas as instâncias de uma execução distribuída tenham a mesma versão
# e os mesmos plugins instalados.
set -euo pipefail

JMETER_VERSION="5.6.3"
INSTALL_DIR="/opt/jmeter"
PLUGINS_MANAGER_VERSION="1.11"

sudo apt-get update -y
sudo apt-get install -y openjdk-17-jre-headless wget tar gettext-base

sudo mkdir -p "$INSTALL_DIR"
cd /tmp
wget -q "https://archive.apache.org/dist/jmeter/binaries/apache-jmeter-${JMETER_VERSION}.tgz"
sudo tar -xzf "apache-jmeter-${JMETER_VERSION}.tgz" -C "$INSTALL_DIR" --strip-components=1
sudo chown -R "$(whoami)":"$(whoami)" "$INSTALL_DIR"

# Plugin Custom Thread Groups (jpgc-casutg), via linha de comando
wget -q -O "$INSTALL_DIR/lib/ext/jmeter-plugins-manager.jar" \
  "https://repo1.maven.org/maven2/kg/apc/jmeter-plugins-manager/${PLUGINS_MANAGER_VERSION}/jmeter-plugins-manager-${PLUGINS_MANAGER_VERSION}.jar"

cd "$INSTALL_DIR"
java -cp "lib/ext/jmeter-plugins-manager.jar" org.jmeterplugins.repository.PluginManagerCMDInstaller
chmod +x bin/PluginsManagerCMD.sh
./bin/PluginsManagerCMD.sh install jpgc-casutg

# Drivers JDBC (postgresql + cliente do OJP) - pegos da pasta jdbc-drivers/
# na raiz do pacote (../jdbc-drivers a partir de vm03/vm04).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DRIVERS_DIR="$SCRIPT_DIR/jdbc-drivers"
[[ -d "$DRIVERS_DIR" ]] || DRIVERS_DIR="$SCRIPT_DIR/../jdbc-drivers"
if [[ -d "$DRIVERS_DIR" ]]; then
  cp "$DRIVERS_DIR"/*.jar "$INSTALL_DIR/lib/"
  echo "Drivers JDBC copiados para $INSTALL_DIR/lib/"
else
  echo "AVISO: pasta jdbc-drivers/ não encontrada - copie manualmente o postgresql-*.jar e o openjproxy.jar para $INSTALL_DIR/lib/"
fi

echo ""
echo "JMeter ${JMETER_VERSION} instalado em ${INSTALL_DIR}."
echo "Adicione ao PATH (ex.: no ~/.bashrc): export PATH=\$PATH:${INSTALL_DIR}/bin"
