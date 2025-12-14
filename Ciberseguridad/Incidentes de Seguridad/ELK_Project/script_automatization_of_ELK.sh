#!/bin/bash

# Script profesional Elastic + Kibana + Logstash 8.x
# Totalmente automático y plug-and-play

set -e

echo "🔹 Configuración de Elasticsearch y Kibana"

# 0️⃣ Preguntar la IP de la interfaz de red
read -p "Introduce la IP que quieres usar para Elasticsearch/Kibana/Logstash (por defecto detecta la IP local): " HOST_IP
if [ -z "$HOST_IP" ]; then
  # Detectar automáticamente la IP local
  HOST_IP=$(hostname -I | awk '{print $1}')
  echo "⚡ Usando IP detectada: $HOST_IP"
fi

# 1️⃣ Pedir contraseñas
read -s -p "Introduce la contraseña para el usuario 'elastic': " ELASTIC_PASSWORD
echo
if [ ${#ELASTIC_PASSWORD} -lt 6 ]; then
  echo "❌ La contraseña debe tener al menos 6 caracteres."
  exit 1
fi

read -p "Introduce el nombre de usuario para Kibana: " KIBANA_USER
read -s -p "Introduce la contraseña para '$KIBANA_USER': " KIBANA_PASSWORD
echo
if [ ${#KIBANA_PASSWORD} -lt 6 ]; then
  echo "❌ La contraseña de Kibana debe tener al menos 6 caracteres."
  exit 1
fi

# 2️⃣ Crear archivo .env
cat > .env <<EOF
ELASTIC_PASSWORD=$ELASTIC_PASSWORD
KIBANA_USER=$KIBANA_USER
KIBANA_PASSWORD=$KIBANA_PASSWORD
HOST_IP=$HOST_IP
EOF
echo "✅ Archivo .env creado."

# 3️⃣ Crear docker-compose.yml
cat > docker-compose.yml <<'EOF'
version: '3.8'

services:
  elasticsearch:
    image: docker.elastic.co/elasticsearch/elasticsearch:8.15.0
    container_name: elasticsearch
    environment:
      - discovery.type=single-node
      - ES_JAVA_OPTS=-Xms1g -Xmx3g
      - xpack.security.enabled=true
      - ELASTIC_PASSWORD=${ELASTIC_PASSWORD}
    ports:
      - "${HOST_IP}:9200:9200"
    volumes:
      - es_data:/usr/share/elasticsearch/data
    networks:
      - es_network

  kibana:
    image: docker.elastic.co/kibana/kibana:8.15.0
    container_name: kibana
    env_file:
      - .env
    environment:
      - ELASTICSEARCH_HOSTS=http://${HOST_IP}:9200
      - ELASTICSEARCH_USERNAME=${KIBANA_USER}
      - ELASTICSEARCH_PASSWORD=${KIBANA_PASSWORD}
      - SERVER_HOST=0.0.0.0
      - XPACK_FLEET_ENABLED=true
    ports:
      - "${HOST_IP}:5601:5601"
    depends_on:
      - elasticsearch
    networks:
      - es_network

  logstash:
    image: docker.elastic.co/logstash/logstash:8.15.0
    container_name: logstash
    env_file:
      - .env
    volumes:
      - ./logstash/pipeline:/usr/share/logstash/pipeline
    ports:
      - "${HOST_IP}:1514:1514/udp"
    environment:
      - xpack.monitoring.enabled=false
    depends_on:
      - elasticsearch
    networks:
      - es_network

volumes:
  es_data:

networks:
  es_network:
    driver: bridge
EOF
echo "✅ docker-compose.yml creado."

# 4️⃣ Crear pipeline Logstash si no existe
mkdir -p logstash/pipeline
if [ ! -f logstash/pipeline/syslog.conf ]; then
cat > logstash/pipeline/syslog.conf <<'EOF'
input {
  udp {
    port => 1514
    type => "syslog"
  }
}

filter {
  if [type] == "syslog" {
    grok {
      match => { "message" => "%{SYSLOGBASE}" }
    }
  }
}

output {
  elasticsearch {
    hosts => ["http://${HOST_IP}:9200"]
    user => "elastic"
    password => "${ELASTIC_PASSWORD}"
    index => "syslog-%{+YYYY.MM.dd}"
  }
  stdout { codec => rubydebug }
}
EOF
  echo "✅ Pipeline syslog.conf creado."
else
  echo "⚠️ Ya existe logstash/pipeline/syslog.conf, no se sobrescribe."
fi

# 5️⃣ Levantar Elasticsearch
echo "⏳ Levantando Elasticsearch..."
docker compose up -d elasticsearch

# 6️⃣ Esperar a que Elasticsearch esté listo
echo "⏳ Esperando a que Elasticsearch esté disponible..."
until curl -s -k -u "elastic:${ELASTIC_PASSWORD}" http://${HOST_IP}:9200 >/dev/null 2>&1; do
  sleep 5
done
echo "✅ Elasticsearch listo."

# 7️⃣ Crear usuario Kibana automáticamente
echo "⏳ Creando usuario de Kibana '$KIBANA_USER'..."
docker exec -i elasticsearch /bin/bash <<EOF
curl -s -k -u "elastic:${ELASTIC_PASSWORD}" -X POST "http://${HOST_IP}:9200/_security/user/$KIBANA_USER" -H 'Content-Type: application/json' -d'
{
  "password" : "'"${KIBANA_PASSWORD}"'",
  "roles" : [ "kibana_system" ],
  "full_name": "Kibana System User",
  "email": "kibana@localhost"
}
'
EOF
echo "✅ Usuario Kibana creado."

# 8️⃣ Levantar Kibana y Logstash
echo "⏳ Levantando Kibana y Logstash..."
docker compose up -d kibana logstash

echo "🎉 Todo listo. Elasticsearch, Kibana y Logstash funcionando."
echo "Accede a Kibana en http://${HOST_IP}:5601 con el usuario '$KIBANA_USER'."
