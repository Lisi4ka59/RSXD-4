# 00. Запустить докер
# 0. Создаём сеть для контейнеров
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

# 2. Запускаем master с монтированием только /data
docker run -d --name pg_master   --network pgnet -p 15432:5432 \
  -e POSTGRES_PASSWORD=masterpass \
  -v /tmp/pg_master/data:/var/lib/postgresql/data \
  postgres:15

# 3. Конфигурируем мастер для репликации
docker exec -u root -it pg_master bash -c "cat <<'EOF' >> /var/lib/postgresql/data/postgresql.conf
wal_level = replica
max_wal_senders = 10
EOF"

docker exec -u root -it pg_master bash -c "cat <<'EOF' >> /var/lib/postgresql/data/pg_hba.conf
host replication replicator 0.0.0.0/0 md5
EOF"

# перезагружаем конфиг
docker exec -u postgres -it pg_master pg_ctl -D /var/lib/postgresql/data reload

# создаём роль репликатора и базу
docker exec -u postgres -it pg_master psql -c \
  "CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'replpass';"
docker exec -u postgres -it pg_master psql -c \
  "CREATE DATABASE blackbox;"

# 4. Сохраняем бэкап master-data для отката
cp -a /tmp/pg_master/data /tmp/pg_master_backup_data

# 5. Настраиваем standby через pg_basebackup
# может занять некоторое время
docker run --rm --name pg_basebackup --network pgnet \
  -v /tmp/pg_standby/data:/var/lib/postgresql/data \
  postgres:15 bash -c "
    PGPASSWORD=replpass pg_basebackup \
      -h pg_master -U replicator \
      -D /var/lib/postgresql/data \
      -Fp -Xs -P
  "

cat <<EOF >> /tmp/pg_standby/data/postgresql.conf
primary_conninfo = 'host=pg_master port=5432 user=replicator password=replpass'
hot_standby = on
max_wal_senders = 10
EOF

# создаём пустой файл standby.signal
touch /tmp/pg_standby/data/standby.signal

# запускаем новый контейнер standby
docker run -d --name pg_standby --network pgnet -p 15433:5432 \
  -e POSTGRES_PASSWORD=standbypass \
  -v /tmp/pg_standby/data:/var/lib/postgresql/data \
  postgres:15

docker exec -u root pg_standby bash -c "
  touch /var/lib/postgresql/data/standby.signal
  chown postgres:postgres /var/lib/postgresql/data/standby.signal
"

# перезапускаем standby
docker restart pg_standby

# 6. Оставляем следы на мастере
# одновременно подключаемся из двух терминалов и заполняем БД
docker exec -u postgres -it pg_master psql -d blackbox

# из терминала 1
echo "
CREATE TABLE user_info (
    user_id SERIAL PRIMARY KEY,
    nickname TEXT NOT NULL,
    email TEXT UNIQUE NOT NULL,
    created_at TIMESTAMP DEFAULT NOW()
);
"

# из терминала 2
echo "
CREATE TABLE user_role (
    role_id SERIAL PRIMARY KEY,
    user_id INT REFERENCES user_info(user_id) ON DELETE CASCADE,
    role_name TEXT NOT NULL,
    granted_at TIMESTAMP DEFAULT NOW()
);
"

# из терминала 1
echo "
BEGIN;

INSERT INTO user_info(nickname, email)
VALUES ('kindred', 'kindred@example.com');

INSERT INTO user_role(user_id, role_name)
SELECT user_id, 'admin' FROM user_info WHERE nickname = 'kindred';

COMMIT;
"

# из терминала 2
echo "
BEGIN;

INSERT INTO user_info(nickname, email)
VALUES ('hokure', 'hokure@example.com');

INSERT INTO user_role(user_id, role_name)
SELECT user_id, 'moderator' FROM user_info WHERE nickname = 'hokure';

COMMIT;
"

# из терминала 1
echo "
BEGIN;

INSERT INTO user_info(nickname, email)
VALUES ('lisi4ka59', 'lisi4ka59@example.com');

INSERT INTO user_role(user_id, role_name)
SELECT user_id, 'user' FROM user_info WHERE nickname = 'lisi4ka59';

COMMIT;
"

echo "
\d
"
echo "
SELECT * FROM user_info;
"

# из терминала 2
echo "
\d
"
echo "
SELECT * FROM user_role;
"

# отключаемся от мастер узла
echo "
\q
"

# подключаемся к pg_standby и проверяем, что там есть записи из мастер узла
docker exec -u postgres -it pg_standby psql -d blackbox

echo "
\d
"
echo "
SELECT * FROM user_info;
"
echo "
SELECT * FROM user_role;
"

# на всякий случай проверяем, что не можем писать в pg_standby
echo "
BEGIN;

INSERT INTO user_info(nickname, email)
VALUES ('lisi4ka', 'lisi4ka@example.com');

INSERT INTO user_role(user_id, role_name)
SELECT user_id, 'user' FROM user_info WHERE nickname = 'lisi4ka';

COMMIT;
"

# отключаемся от standby узла
echo "
\q
"

# 7. Заполняем файловую систему мусорным файлом (на хосте)
dd if=/dev/zero of=/tmp/pg_master/data/filler bs=4096 status=progress || true

# проверяем, что там не осталось места
df -h /tmp/pg_master/data

# снова подключаемся к мастер узлу, который хотим испортить и делаем еще один insert
docker exec -u postgres -it pg_master psql -d blackbox
echo "
BEGIN;

INSERT INTO user_info(nickname, email)
VALUES ('lisi4ka', 'lisi4ka@example.com');

INSERT INTO user_role(user_id, role_name)
SELECT user_id, 'user' FROM user_info WHERE nickname = 'lisi4ka';

COMMIT;
"
echo "
\q
"

# пытаемся подключиться и видим ошибку (FATAL:  the database system is in recovery mode)
docker exec -u postgres -it pg_master psql -d blackbox

# поздравляю, ты все сломал!

# 8. промотирование standby
docker exec -u postgres -it pg_standby pg_ctl -D /var/lib/postgresql/data promote

# записываем в standby новую информацию
docker exec -u postgres -it pg_standby psql -d blackbox
echo "
BEGIN;

INSERT INTO user_info(nickname, email)
VALUES ('Бабка_в_танке', 'turms@example.com');

INSERT INTO user_role(user_id, role_name)
SELECT user_id, 'user' FROM user_info WHERE nickname = 'Бабка_в_танке';

COMMIT;
"
echo "
SELECT * FROM user_info;
"
echo "
SELECT * FROM user_role;
"
echo "
\q
"

# 9. Восстановление master
docker stop pg_master

# находим процессы, которые используют наш том и убиваем их
sudo lsof +D /tmp/pg_master
kill -9 12345

# отмонтируем том и пересоздадим его (от этого сдохнет докер)
hdiutil detach /tmp/pg_master
rm pg_master.dmg
hdiutil create -size 500m -fs HFS+ -volname pg_master   pg_master.dmg
hdiutil attach pg_master.dmg -mountpoint /tmp/pg_master

# запустить докер и контейнер pg_standby
docker start pg_standby

# запускаем мастер узел
docker start pg_master

# делаем dump и восстанавливаем мастер узел
docker exec -u postgres -it pg_standby pg_dumpall \
  > standby_changes.sql
docker cp standby_changes.sql pg_master:/tmp/standby_changes.sql
docker exec -u postgres -it pg_master psql -f /tmp/standby_changes.sql

# можно зайти на мастер узел и посмотреть, что все изменения накатились
docker exec -u postgres -it pg_master psql -d blackbox
echo "
SELECT * FROM user_info;
"
echo "
SELECT * FROM user_role;
"
echo "
\q
"

# 10. Восстановление резервного узла в исходное состояние
# остановить и удалить старый контейнер standby
docker stop pg_standby
docker rm   pg_standby

# очистить данные standby на хосте
rm -rf /tmp/pg_standby/data/*

cat <<EOF >> /tmp/pg_master/data/pg_hba.conf
host  replication  replicator  172.18.0.0/16  md5
EOF

# перезагрузить конфиг внутри контейнера-мастера
docker exec -u postgres pg_master pg_ctl \
  -D /var/lib/postgresql/data reload

# получаем свежий слепок от мастера через pg_basebackup
docker run --rm --name pg_basebackup --network pgnet \
  -v /tmp/pg_standby/data:/var/lib/postgresql/data \
  postgres:15 bash -c "
    PGPASSWORD=replpass pg_basebackup \
      -h pg_master -U replicator \
      -D /var/lib/postgresql/data \
      -Fp -Xs -P
  "

# настраиваем standby mode
cat <<EOF >> /tmp/pg_standby/data/postgresql.conf
primary_conninfo = 'host=pg_master port=5432 user=replicator password=replpass'
hot_standby = on
max_wal_senders = 10
EOF

# создаём пустой файл standby.signal
touch /tmp/pg_standby/data/standby.signal

# запускаем новый контейнер-standby
docker run -d --name pg_standby --network pgnet -p 15433:5432 \
  -e POSTGRES_PASSWORD=standbypass \
  -v /tmp/pg_standby/data:/var/lib/postgresql/data \
  postgres:15

docker exec -u root pg_standby bash -c "
  touch /var/lib/postgresql/data/standby.signal
  chown postgres:postgres /var/lib/postgresql/data/standby.signal
"

docker restart pg_standby

# 11. Финальная проверка
# подключаемся к standby и пробуем сделать insert (должна быть ошибка: cannot execute INSERT in a read-only transaction)
docker exec -u postgres -it pg_standby psql -d blackbox
echo "
SELECT * FROM user_info;
"
echo "
SELECT * FROM user_role;
"
echo "
BEGIN;

INSERT INTO user_info(nickname, email)
VALUES ('Диванный_генерал', 'abrams@example.com');

INSERT INTO user_role(user_id, role_name)
SELECT user_id, 'user' FROM user_info WHERE nickname = 'Диванный_генерал';

COMMIT;
"
echo "
\q
"

# подключаемся к мастер узлу, проверяем, что все данные на месте и добавляем новые записи
docker exec -u postgres -it pg_master psql -d blackbox
echo "
BEGIN;

INSERT INTO user_info(nickname, email)
VALUES ('Диванный_генерал', 'abrams@example.com');

INSERT INTO user_role(user_id, role_name)
SELECT user_id, 'user' FROM user_info WHERE nickname = 'Диванный_генерал';

COMMIT;
"
echo "
SELECT * FROM user_info;
"
echo "
SELECT * FROM user_role;
"
echo "
\q
"

# подключаемся к standby и смотрим, что репликация прошла успешно
docker exec -u postgres -it pg_standby psql -d blackbox
echo "
SELECT * FROM user_info;
"
echo "
SELECT * FROM user_role;
"
echo "
\q
"

# все получилось, вы восхитительны!