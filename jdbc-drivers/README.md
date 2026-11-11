# Drivers JDBC

`install-jmeter.sh` (VM03, VM04 e VM05) copia todos os `.jar` desta pasta para `/opt/jmeter/lib/`.

- `postgresql-42.7.13.jar`: pgJDBC, usado nos cenários 1 a 3 (incluído).
- *Driver* do OJP 0.5.4-beta (`org.openjproxy:ojp-jdbc-driver:0.5.4-beta`, com as dependências gRPC): baixe e coloque aqui antes da instalação. Usado no cenário 4.
