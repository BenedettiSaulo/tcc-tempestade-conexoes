# Tempestades de conexões: PgBouncer, ProxySQL e Open J Proxy

Ambiente experimental do Trabalho de Conclusão de Curso **"Mitigação de tempestades de conexões em bancos de dados relacionais: uma análise de desempenho e arquitetura entre PgBouncer, ProxySQL e Open J Proxy"** (Sistemas de Informação, UNOESC Chapecó, 2026), de Saulo Lucio Benedetti, sob orientação do Prof. Álvaro Gianni Pagliari.

O repositório reúne os arquivos de implantação, as configurações dos proxies, os planos de teste do Apache JMeter e os *scripts* de orquestração e de coleta usados nos experimentos. Com eles, é possível reproduzir o ambiente e os dois experimentos descritos no artigo.

## O que é comparado

Quatro cenários de acesso a um PostgreSQL 17 (`max_connections = 100`, base Pagila), todos com a mesma carga:

| Cenário | Componentes na VM02 | *Driver* no cliente | Porta |
|---|---|---|---|
| 1. Sem proxy (*baseline*) | nenhum | pgJDBC 42.7.13 | 5432 (VM01) |
| 2. PgBouncer + HAProxy | HAProxy (TCP) → PgBouncer, modo `transaction`, 50 conexões | pgJDBC 42.7.13 | 6433 |
| 3. ProxySQL | ProxySQL 3.0.4 (módulo PostgreSQL), 50 conexões | pgJDBC 42.7.13 | 6033 |
| 4. OJP | servidor Open J Proxy 0.5.4-beta (gRPC), *pool* de 50 | *driver* OJP 0.5.4-beta | 1059 |

A carga usa o *Open Model Thread Group* (malha aberta, taxa de chegada fixa) e um amostrador JSR223 em Groovy que abre uma conexão nova a cada requisição, executa um `SELECT` com junções e agregação e um `UPDATE` de uma linha, confirma e fecha a conexão.

## Topologia

Cinco máquinas virtuais Ubuntu em um servidor Proxmox VE, em rede interna:

| VM | Função | vCPU / RAM | Pasta deste repositório |
|---|---|---|---|
| VM01 | PostgreSQL 17 + Pagila | 4 / 16 GB | `vm01-db/` |
| VM02 | Proxies (um cenário ativo por vez) | 2 / 4 GB | `vm02-proxies/` |
| VM03 | Orquestrador JMeter (não gera carga) | 2 / 4 GB | `vm03-jmeter-master/` |
| VM04 | Gerador de carga JMeter | 2 / 4 GB | `vm04-jmeter-worker/` |
| VM05 | Gerador de carga JMeter | 2 / 4 GB | `vm05-jmeter-worker/` |

## Estrutura

```
vm01-db/                 docker-compose do PostgreSQL, base Pagila (init-db/),
                         recriação do banco e amostradores de CPU/conexões
vm02-proxies/            docker-compose dos proxies, templates de configuração
                         (PgBouncer, ProxySQL), haproxy.cfg e libs do OJP
vm03-jmeter-master/      planos de teste (tcc_bench.jmx, tcc_retry.jmx) e
                         scripts de orquestração das baterias
vm04-jmeter-worker/      instalação e serviço do jmeter-server
vm05-jmeter-worker/      idem, para o segundo gerador
jdbc-drivers/            drivers JDBC copiados para o JMeter na instalação
DEPLOY.md                passo a passo detalhado da implantação
```

## Como reproduzir

O passo a passo completo está em [`DEPLOY.md`](DEPLOY.md). Em resumo:

1. **VM01:** `cd vm01-db && docker compose up -d`.
2. **VM02:** `cp .env.example .env` (com o IP da VM01), `./render-configs.sh` e `docker compose up -d`.
3. **VM04 e VM05:** copie a pasta do *worker* e `jdbc-drivers/` lado a lado, rode `./install-jmeter.sh` e `./start-worker.sh <IP_DA_VM>`.
4. **VM03:** copie `vm03-jmeter-master/` e `jdbc-drivers/`, rode `./install-jmeter.sh`, crie `servers.env` a partir de `servers.env.example` e configure SSH sem senha para a VM01 e a VM02.

### Bateria principal (taxa fixa)

```bash
cd vm03-jmeter-master
./run-all-benchmarks-distributed.sh --rate 160 --duration 60      # os 4 cenários
./run-all-benchmarks-distributed.sh --rate 350 --duration 60 4    # só o OJP
```

Cada execução recria o banco, mantém ativo apenas o proxy do cenário, faz um aquecimento de 20 s a 25% da taxa (descartado), coleta CPU e memória dos contêineres na VM01 e na VM02 e grava os resultados em `reports/<cenario>/<data_hora>/`. No artigo foram usadas as taxas de 160, 200, 300 e 350 req/s, com três repetições.

### Experimento complementar (pico com novas tentativas)

```bash
./run-retry-experiment.sh                 # 3 blocos x 4 cenários, ordem em quadrado latino
```

Perfil: 160 req/s por 30 s, pico de 400 req/s por 30 s e 160 req/s por 90 s, com até quatro tentativas por requisição e recuo exponencial com *jitter*. Em paralelo, `vm01-db/pg-sampler.sh` registra a cada segundo as conexões, as consultas ativas e as esperas por *lock* no banco.

## Drivers JDBC

`jdbc-drivers/` já traz o pgJDBC 42.7.13. O *driver* JDBC do OJP 0.5.4-beta (artefato Maven `org.openjproxy:ojp-jdbc-driver:0.5.4-beta`, do projeto [Open J Proxy](https://github.com/Open-J-Proxy/ojp)) deve ser baixado e colocado na mesma pasta antes de rodar `install-jmeter.sh`. A pasta `vm02-proxies/ojp-libs/` contém o pgJDBC usado pelo servidor OJP para acessar o PostgreSQL.

## Observações

- As credenciais (`postgres`/`postgres`, `admin`/`admin` no ProxySQL) e os IPs `10.0.0.x` são valores de laboratório, usados em uma rede interna e isolada. Não use essas configurações em produção.
- No ProxySQL, a autenticação em texto claro no *front-end* (`authentication_method = 2`) só foi aceitável por causa dessa rede isolada.
- Os resultados do artigo valem para esse ambiente e essas versões. As imagens Docker exatas (*digests*) estão listadas no Apêndice A do artigo.
