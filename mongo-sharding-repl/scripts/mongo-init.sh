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

# Ждем, пока все реплики конфигурационного сервера будут готовы
wait_for_mongo configSrv1 27017
wait_for_mongo configSrv2 27021
wait_for_mongo configSrv3 27022

# Ждем, пока все реплики каждого шарда будут готовы
wait_for_mongo shard1-primary 27018
wait_for_mongo shard1-secondary1 27024
wait_for_mongo shard1-secondary2 27025
wait_for_mongo shard2-primary 27019
wait_for_mongo shard2-secondary1 27026
wait_for_mongo shard2-secondary2 27027

# === ИНИЦИАЛИЗАЦИЯ КОНФИГУРАЦИОННОГО СЕРВЕРА ===
echo "Инициализация конфигурационного сервера начата"
docker exec -i configSrv1 mongosh --port 27017 <<EOF
rs.initiate({
  _id: "configReplSet",
  configsvr: true,
  members: [
    { _id: 0, host: "configSrv1:27017" },
    { _id: 1, host: "configSrv2:27021" },
    { _id: 2, host: "configSrv3:27022" }
  ]
});
EOF
echo "Конфигурационный сервер инициализирован"

sleep 10  # Ждём стабилизации кластера

# === ИНИЦИАЛИЗАЦИЯ ШАРДОВ ===
echo "Инициализация shard1 начата"
docker exec -i shard1-primary mongosh --port 27018 <<EOF
rs.initiate({
  _id: "shard1ReplSet",
  members: [
    { _id: 0, host: "shard1-primary:27018" },
    { _id: 1, host: "shard1-secondary1:27024" },
    { _id: 2, host: "shard1-secondary2:27025" }
  ]
});
EOF

echo "shard1 инициализирован"
echo "Инициализация shard1 начата"
docker exec -i shard2-primary mongosh --port 27019 <<EOF
rs.initiate({
  _id: "shard2ReplSet",
  members: [
    { _id: 0, host: "shard2-primary:27019" },
    { _id: 1, host: "shard2-secondary1:27026" },
    { _id: 2, host: "shard2-secondary2:27027" }
  ]
});
EOF

echo "shard2 инициализирован"
sleep 10  # Ждём стабилизации репликации

# === ИНИЦИАЛИЗАЦИЯ РОУТЕРА (mongos) ===
echo "Инициализация роутера и добавление шардов начата"

docker exec -i mongos_router mongosh --port 27020 <<EOF
sh.addShard("shard1ReplSet/shard1-primary:27018,shard1-secondary1:27024,shard1-secondary2:27025");
sh.addShard("shard2ReplSet/shard2-primary:27019,shard2-secondary1:27024,shard2-secondary2:27025");

sh.enableSharding("somedb");
sh.shardCollection("somedb.helloDoc", { "name" : "hashed" });

use somedb;
for (var i = 0; i < 1000; i++) {
  db.helloDoc.insert({ age: i, name: "ly" + i });
}

print("Количество документов в коллекции helloDoc: " + db.helloDoc.countDocuments());
exit();
EOF

echo "Роутер настроен, шарды добавлены и база данных заполнена"
