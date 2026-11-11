# Deploy do ambiente de benchmark em 5 servidores

## Topologia

```
vm01 (201) - Postgres           4vCPU / 16G / 50G
vm02 (202) - Proxies            2vCPU / 4G  / 25G  (PgBouncer, HAProxy, ProxySQL, OJP)
vm03 (203) - JMeter master      2vCPU / 4G  / 25G  (só orquestra, não gera carga)
vm04 (204) - JMeter worker      2vCPU / 4G  / 25G  (gera a carga de verdade)
vm05 (205) - JMeter worker      2vCPU / 4G  / 25G  (gera a carga de verdade)
```

Rede interna /24, sem restrição entre as VMs — não precisei detalhar regras
de firewall porque você já disse que está tudo aberto. Só pra registro no
seu TCC (metodologia), as portas envolvidas são:

| Porta | Onde   | Serviço                                  |
|-------|--------|-------------------------------------------|
| 5432  | vm01   | Postgres                                   |
| 6432  | vm02   | PgBouncer (direto, opcional)               |
| 6433  | vm02   | HAProxy → PgBouncer                        |
| 6033  | vm02   | ProxySQL                                   |
| 1059  | vm02   | OJP (gRPC)                                 |
| 8404  | vm02   | painel de stats do HAProxy                 |
| 1099 + 50000 | vm04 e vm05 | RMI do jmeter-server (controlado pela vm03) |
| 22    | todas  | SSH (usado pelo orquestrador a partir da vm03) |

## Por que o cenário 4 (OJP) agora é mais simples que no ambiente local

No Docker local, o servidor OJP resolvia o Postgres pelo nome do serviço
dentro da rede do compose (`postgres`), o que gerava confusão. Aqui, com
IPs reais e roteáveis entre VMs, isso desaparece: tanto o worker do
JMeter quanto o servidor OJP (na vm02) enxergam a vm01 pelo mesmo IP.

## 0. Preparação: SSH sem senha da vm03 para a vm01 e vm02

O orquestrador (`run-all-benchmarks-distributed.sh`) roda na vm03 e
comanda a vm01/vm02 via SSH. Configure a chave uma vez:

```bash
# na vm03
ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519   # se ainda não tiver uma
ssh-copy-id <usuario>@<IP_VM01>
ssh-copy-id <usuario>@<IP_VM02>
# teste: deve conectar sem pedir senha
ssh <usuario>@<IP_VM01> echo ok
ssh <usuario>@<IP_VM02> echo ok
```

## 1. vm01 - Postgres

```bash
sudo apt-get update && sudo apt-get install -y docker.io docker-compose-plugin
sudo mkdir -p /opt/tcc-benchmark/vm01-db && sudo chown $USER /opt/tcc-benchmark/vm01-db
# copie a pasta vm01-db/ deste pacote para lá (scp, rsync, git, o que preferir)
cd /opt/tcc-benchmark/vm01-db
chmod +x reset-env.sh monitor-hardware.sh
docker compose up -d
docker compose ps   # confirme "healthy"
```

O `max_connections=100` do Postgres foi **mantido de propósito** (não subi
para milhares só porque o servidor tem mais RAM): é exatamente esse teto
modesto, sem pooling na frente, que faz o cenário baseline mostrar
contenção sob carga — é o ponto de comparação que dá sentido ao TCC. Se
achar que precisa de outro valor, mude no `command:` do `docker-compose.yml`
conscientemente, sabendo que isso muda o que o baseline consegue provar.

## 2. vm02 - Proxies

```bash
sudo apt-get update && sudo apt-get install -y docker.io docker-compose-plugin gettext-base
sudo mkdir -p /opt/tcc-benchmark/vm02-proxies && sudo chown $USER /opt/tcc-benchmark/vm02-proxies
# copie a pasta vm02-proxies/ deste pacote para lá
cd /opt/tcc-benchmark/vm02-proxies
cp .env.example .env
nano .env   # DB_HOST=<IP_VM01>
./render-configs.sh   # gera pgbouncer.ini e proxysql.cnf com o IP certo
chmod +x monitor-hardware.sh
docker compose up -d
docker compose ps
```

Confirme que cada proxy realmente alcança a vm01 antes de seguir:

```bash
docker exec tcc-pgbouncer sh -c "nc -zv <IP_VM01> 5432"
docker logs tcc-proxysql --tail 30
docker logs tcc-ojp --tail 30
```

## 3. vm04 - JMeter worker

```bash
# copie vm04-jmeter-worker/ E jdbc-drivers/ (pasta irmã, na raiz do pacote) para lá,
# mantendo os dois lado a lado - ex.: /opt/tcc-benchmark/{vm04-jmeter-worker,jdbc-drivers}
cd vm04-jmeter-worker
./install-jmeter.sh
# rode em foreground pra testar primeiro:
./start-worker.sh <IP_VM04>
```

Se subir certo, você vê `Created remote object` no log e ele fica parado
esperando o master. Pra deixar persistente (sobrevive a queda de SSH),
troque por systemd:

```bash
# edite jmeter-worker.service: <SEU_USUARIO> e <VM04_IP>
sudo cp jmeter-worker.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now jmeter-worker
sudo systemctl status jmeter-worker
```

## 4. vm05 - JMeter worker

```bash
# copie vm05-jmeter-worker/ E jdbc-drivers/ (pasta irmã, na raiz do pacote) para lá,
# mantendo os dois lado a lado - ex.: /opt/tcc-benchmark/{vm05-jmeter-worker,jdbc-drivers}
cd vm05-jmeter-worker
./install-jmeter.sh
# rode em foreground pra testar primeiro:
./start-worker.sh <IP_VM05>
```

Se subir certo, você vê `Created remote object` no log e ele fica parado
esperando o master. Pra deixar persistente (sobrevive a queda de SSH),
troque por systemd:

```bash
# edite jmeter-worker.service: <SEU_USUARIO> e <VM05_IP>
sudo cp jmeter-worker.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now jmeter-worker
sudo systemctl status jmeter-worker
```

## 5. vm03 - JMeter master (orquestrador)

```bash
# copie vm03-jmeter-master/ E jdbc-drivers/ (pasta irmã) para lá,
# mesmo esquema da vm04: /opt/tcc-benchmark/{vm03-jmeter-master,jdbc-drivers}
cd vm03-jmeter-master
./install-jmeter.sh
cp servers.env.example servers.env
nano servers.env   # DB_HOST, PROXY_HOST, JMETER_WORKER_HOSTS (vm04,vm05), SSH_USER, os *_REMOTE_DIR
chmod +x run-all-benchmarks-distributed.sh
export PATH=$PATH:/opt/jmeter/bin
```

Teste rápido de conectividade antes da bateria completa (dispara só o
cenário 1, sem passar pelos proxies, pra validar RMI + banco):

```bash
jmeter -n -t tcc_bench.jmx -R <IP_VM04> -Dserver.rmi.ssl.disable=true \
  -JTARGET_SCENARIO=1 -JDB_HOST=<IP_VM01> -JTARGET_RATE=10 -JTEST_DURATION=10 \
  -l reports/teste_conectividade.jtl
```
Se aparecer erro de RMI (`Connection refused`, `UnmarshalException`), o
mais comum é o `java.rmi.server.hostname` do worker não bater com o IP
real, ou firewall bloqueando a porta 50000 — confirme com
`nc -zv <IP_VM04> 1099` e `nc -zv <IP_VM04> 50000` a partir da vm03.

Depois disso, a bateria completa:

```bash
./run-all-benchmarks-distributed.sh                          # os 4 cenários
./run-all-benchmarks-distributed.sh --rate 500 --duration 180 # sobe a carga
./run-all-benchmarks-distributed.sh 4                          # só o OJP
```

## Onde ficam as 3 métricas que você pediu

Throughput, taxa de erro e latência **já saem prontas de cada rodada**,
sem ferramenta extra — é o que o próprio dashboard HTML do JMeter
(`reports/html_<cenario>_<timestamp>/index.html`, gerado pelo `-e -o`)
mostra nas abas "Dashboard" (throughput ao longo do tempo, taxa de erro)
e "Charts" (tempos de resposta, percentis). O `resumo_geral.csv` puxa os
mesmos números de cada rodada (`amostras, erros, erro_pct, media_ms,
p90_ms, p95_ms, p99_ms, throughput_req_s`) numa linha só por cenário —
essa é a tabela pra jogar direto num gráfico comparativo final entre os
4 cenários no TCC.

CPU/memória de cada servidor (vm01 e vm02) ficam em
`reports/db_<cenario>_<timestamp>.csv` e `reports/proxy_<cenario>_<timestamp>.csv`,
já trazidos pra vm03 automaticamente ao fim de cada rodada — sem
Prometheus/Grafana, é abrir no Excel/LibreOffice e plotar CPU%/memória
por container ao longo do tempo, com o pico visível durante o platô de
carga.

## Checklist antes de confiar no resultado final

- [ ] Rodou o teste de conectividade do passo 4 e viu o worker aceitar o
      comando do master sem erro de RMI.
- [ ] Conferiu que `resumo_geral.csv` tem valores **diferentes** de
      `erro_pct`/`media_ms` entre os 4 cenários (se todos derem
      exatamente igual de novo, é sinal de que algo ainda está sempre
      caindo no mesmo cenário — repita o problema que corrigimos no
      `TARGET_SCENARIO` acima, mas em outro lugar).
- [ ] Abriu pelo menos um dos CSVs de hardware e viu picos de CPU/memória
      alinhados com o horário do platô de carga (não uma linha reta
      entediante o teste inteiro).
