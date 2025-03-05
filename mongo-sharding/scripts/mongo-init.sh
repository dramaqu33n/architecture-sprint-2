#!/bin/bash

echo "Инициализация кластера MongoDB начата"

# === ОЖИДАНИЕ ГОТОВНОСТИ КОНТЕЙНЕРОВ ===
function wait_for_mongo() {
  local container=$1
  local port=$2
  echo "Ожидание готовности $container на порту $port..."
  until docker exec -i "$container" mongosh --quiet --port "$port" --eval "db.runCommand({ ping: 1 })" | grep -q "ok"; do
    sleep 2
  done
  echo "$container готов к работе"
}

wait_for_mongo configSrv 27017
wait_for_mongo shard1 27018
wait_for_mongo shard2 27019

# === ИНИЦИАЛИЗАЦИЯ КОНФИГА ===
echo "Инициализация конфигурационного сервера начата"
docker exec -i configSrv mongosh --host configSrv --port 27017 <<EOF
rs.initiate({
  _id: "config_server",
  configsvr: true,
  members: [{ _id: 0, host: "configSrv:27017" }]
});
EOF
echo "Конфигурационный сервер инициализирован"

sleep 5

# === ИНИЦИАЛИЗАЦИЯ ШАРДОВ ===
for shard in shard1 shard2; do
  port=$((27017 + ${shard: -1})) 
  echo "Инициализация $shard начата"
  docker exec -i "$shard" mongosh --host "$shard" --port "$port" <<EOF
rs.initiate({
  _id: "$shard",
  members: [{ _id: 0, host: "$shard:$port" }]
});
EOF
  echo "$shard инициализирован"
  sleep 5
done

# Инициализация роутера и добавление шардов
echo "Инициализация роутера и добавление шардов начата"

docker exec -i mongos_router mongosh --port 27020 <<EOF
sh.addShard("shard1/shard1:27018");
sh.addShard("shard2/shard2:27019");

sh.enableSharding("somedb");
sh.shardCollection("somedb.helloDoc", { "name" : "hashed" });

use somedb;
for (var i = 0; i < 1000; i++) {
  db.helloDoc.insert({ age: i, name: "ly" + i });
}

print("Количество документов в коллекции helloDoc: " + db.helloDoc.countDocuments());
exit();
EOF

docker exec -i shard1 mongosh --port 27018 <<EOF
use somedb;
print("Количество документов на shard1: " + db.helloDoc.countDocuments());
exit();
EOF

docker exec -i shard2 mongosh --port 27019 <<EOF
use somedb;
print("Количество документов на shard2: " + db.helloDoc.countDocuments());
exit();
EOF

echo "Роутер настроен, шарды добавлены и база данных заполнена"

