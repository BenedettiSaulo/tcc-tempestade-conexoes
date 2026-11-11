echo "epoch_ms,conexoes_cliente,ativas" > conexoes_pg.csv
while true; do
  ts=$(date +%s%3N)
  r=$(docker exec tcc-postgres psql -U postgres -d pagila -tA -F, -c \
    "select count(*) filter (where backend_type='client backend'), count(*) filter (where backend_type='client backend' and state='active') from pg_stat_activity" 2>/dev/null)
  [[ -n "$r" ]] && echo "$ts,$r" >> conexoes_pg.csv
  sleep 1
done
