# КОМАНДЫ ДЛЯ СНОСА КОНТЕЙНЕРОВ

# 1. Остановить и удалить контейнеры
docker stop pg_master pg_standby
docker rm   pg_master pg_standby

# 2. Удалить Docker-сеть
docker network rm pgnet

# 3. Находим процессы, которые используют томы
sudo lsof +D /tmp/pg_master
sudo lsof +D /tmp/pg_standby

# 4. Убиваем процессы, найденные выше (скорее всего понадобиться убить только один процесс)
kill -9 12345

# 5. Отмонтировать HFS+-тома и удалить их образы (от такого сдохнет докер, не забыть перезапустить)
hdiutil detach /tmp/pg_master
hdiutil detach /tmp/pg_standby
rm pg_master.dmg pg_standby.dmg

# 6. Удалить каталоги с данными на хосте
rm -rf /tmp/pg_master /tmp/pg_standby