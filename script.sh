#!/bin/bash
set -e

# 0. Создаём сеть для контейнеров (если ещё нет)
docker network create pgnet || true

# 1. Подготовка HFS+-томов по 500 МБ
mkdir -p /tmp/pg_master /tmp/pg_standby

hdiutil create -size 500m -fs HFS+ -volname pg_master   pg_master.dmg
hdiutil attach pg_master.dmg -mountpoint /tmp/pg_master

hdiutil create -size 500m -fs HFS+ -volname pg_standby pg_standby.dmg
hdiutil attach pg_standby.dmg -mountpoint /tmp/pg_standby

# внутри каждого тома создаём чистый каталог data и даём права postgres (UID 999)
docker run --rm -v /tmp/pg_master:/mnt alpine sh -c "mkdir -p /mnt/data && chown 999:999 /mnt/data"
docker run --rm -v /tmp/pg_standby:/mnt alpine sh -c "mkdir -p /mnt/data && chown 999:999 /mnt/data"

# 2. Запускаем master и standby с монтированием только /data
docker run -d --name pg_master   --network pgnet -p 15432:5432 \
  -e POSTGRES_PASSWORD=masterpass \
  -v /tmp/pg_master/data:/var/lib/postgresql/data \
  postgres:15

docker run -d --name pg_standby --network pgnet -p 15433:5432 \
  -e POSTGRES_PASSWORD=standbypass \
  -v /tmp/pg_standby/data:/var/lib/postgresql/data \
  postgres:15

sleep 10  # подождать инициализацию

# 3. Конфигурируем мастер для репликации

# 3.1 Правим postgresql.conf и pg_hba.conf через cat
docker exec -u root -it pg_master bash -c "cat <<'EOF' >> /var/lib/postgresql/data/postgresql.conf
wal_level = replica
max_wal_senders = 10
EOF"

docker exec -u root -it pg_master bash -c "cat <<'EOF' >> /var/lib/postgresql/data/pg_hba.conf
host replication replicator 0.0.0.0/0 md5
EOF"

# 3.2 Перезагружаем конфиг (от postgres-пользователя)
docker exec -u postgres -it pg_master pg_ctl -D /var/lib/postgresql/data reload

# 3.3 Создаём роль репликатора, базу и таблицу
docker exec -u postgres -it pg_master psql -c \
  "CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'replpass';"
docker exec -u postgres -it pg_master psql -c \
  "CREATE DATABASE demo;"
docker exec -u postgres -it pg_master psql -d demo -c \
  "CREATE TABLE t1(id serial PRIMARY KEY, msg text);"

# 4. Сохраняем бэкап master-data для отката
cp -a /tmp/pg_master/data /tmp/pg_master_backup_data

# 5. Настраиваем standby через pg_basebackup (PG15+)
docker exec -u root pg_standby bash -c "rm -rf /var/lib/postgresql/data/*"

docker run --rm --name pg_basebackup --network pgnet \
  -v /tmp/pg_standby/data:/var/lib/postgresql/data \
  postgres:15 bash -c "
    PGPASSWORD=replpass pg_basebackup \
      -h pg_master -U replicator \
      -D /var/lib/postgresql/data -Fp -Xs -P
  "

# Правим postgresql.conf и создаём standby.signal
docker exec -u root pg_standby bash -c "cat <<'EOF' >> /var/lib/postgresql/data/postgresql.conf
primary_conninfo = 'host=pg_master port=5432 user=replicator password=replpass'
hot_standby = on
max_wal_senders = 10
EOF
touch /var/lib/postgresql/data/standby.signal
chown postgres:postgres /var/lib/postgresql/data/standby.signal
"

# Перезапускаем standby
docker restart pg_standby
sleep 5

# 6. Шаг 2: «следы» на мастере
echo
echo "→ Step 2: Подключитесь к master и выполните read/write:"
echo "    docker exec -u postgres -it pg_master psql -d demo"
echo "    INSERT INTO t1(msg) VALUES('state-after-step2');"
echo "    SELECT * FROM t1;"
echo
# Подключаемся к pg_standby и проверяем, что там есть записи из мастер узла
echo "    docker exec -u postgres -it pg_standby psql -d demo"
echo "    SELECT * FROM t1;"

# 7. Шаг 3: заполняем файловую систему «чужим» файлом (на хосте)
echo "→ Step 3: Заполняем FS на master:"
dd if=/dev/zero of=/tmp/pg_master/data/filler bs=4096 status=progress || true
df -h /tmp/pg_master/data
echo
# Снова подключаемся к основному узлу, который хотим испортить и он должен либо не подключаться
# Либо, если подключился, то понаинсерти туда строчек, выйди и тогда он точно должен перестать работать
# Что-то типа такого должно получиться
# lisi4ka@MacBook-Pro-Mihail-3 ~ % docker exec -u postgres -it pg_master psql -d demo
# psql: error: connection to server on socket "/var/run/postgresql/.s.PGSQL.5432" failed: FATAL:  the database system is in recovery mode
docker exec -u postgres -it pg_master psql -d demo
echo "    INSERT INTO t1(msg) VALUES('state-after-step2');"

# 8. Шаг 4: промотирование standby + запись туда
echo "→ Step 4: Промотируйте standby и запишите в него:"
echo "    docker exec -u postgres -it pg_standby bash -c \"touch /var/lib/postgresql/data/failover.trigger\""
echo "    sleep 5"
echo "    docker exec -u postgres -it pg_standby psql -d demo"
echo "    docker exec -u postgres -it pg_standby pg_ctl -D /var/lib/postgresql/data promote"
echo "    INSERT INTO t1(msg) VALUES('write-on-standby');"
echo

# 9. Шаг 5: откат master + перенос изменений из standby
echo "→ Step 5: Восстанавливаем master и применяем изменения из standby..."
docker stop pg_master
rm -rf /tmp/pg_master/data/*
cp -a /tmp/pg_master_backup_data/* /tmp/pg_master/data/ # Вот на этом этапе у меня перестало получаться, потому что не удалился мусор
docker start pg_master
sleep 5
docker exec -u postgres -it pg_standby pg_dump -d demo --table=t1 --data-only \
  > standby_changes.sql
docker cp standby_changes.sql pg_master:/tmp/standby_changes.sql
docker exec -u postgres -it pg_master psql -d demo -f /tmp/standby_changes.sql

# Финальная проверка
echo
echo "→ Финальная проверка на master:"
docker exec -u postgres -it pg_master psql -d demo -c "SELECT * FROM t1;"