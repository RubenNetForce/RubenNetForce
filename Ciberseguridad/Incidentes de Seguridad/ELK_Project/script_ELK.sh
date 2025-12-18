#!/bin/bash
set -euo pipefail

# -------------------------------
# VALIDACIONES
# -------------------------------
if [ "$EUID" -ne 0 ]; then
  echo "Ejecuta como root o sudo"
  exit 1
fi

# -------------------------------
# INSTALAR DOCKER SI NO EXISTE
# -------------------------------
if ! command -v docker >/dev/null 2>&1; then
  apt update
  apt install -y ca-certificates curl gnupg

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  cat <<EOF >/etc/apt/sources.list.d/docker.sources
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

  apt update
  apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable docker
  systemctl start docker
fi

# -------------------------------
# VARIABLES
# -------------------------------
read -p "IP del servidor (ip a interfaz por donde salga o se comunique): " HOST_IP
[ -z "$HOST_IP" ] && exit 1

read -s -p "Password elastic: " ELASTIC_PASSWORD
echo
read -s -p "Password kibana_system: " KIBANA_PASSWORD
echo

# -------------------------------
# ENCRYPTION KEYS ALERTING
# -------------------------------
# Generamos 3 claves aleatorias de 32 caracteres
XPACK_ENCRYPTED_SAVED_OBJECTS_KEY=$(openssl rand -hex 32)
XPACK_REPORTING_KEY=$(openssl rand -hex 32)
XPACK_SECURITY_KEY=$(openssl rand -hex 32)

echo "[INFO] Claves de cifrado generadas para Kibana"

# -------------------------------
# DATOS CERTIFICADO
# -------------------------------
read -p "CN (Common Name, por ejemplo elastic.local): " CERT_CN
read -p "O (Organization, por ejemplo Elastic): " CERT_O
read -p "C (Country, por ejemplo ES): " CERT_C

mkdir -p certs logstash/pipeline config

# -------------------------------
# CERTIFICADOS SSL
# -------------------------------
openssl req -x509 -newkey rsa:4096 -nodes -days 365 \
  -keyout certs/elastic.key \
  -out certs/elastic.crt \
  -subj "/CN=${CERT_CN}/O=${CERT_O}/C=${CERT_C}" \
  -addext "subjectAltName=IP:${HOST_IP}"

cp certs/elastic.crt certs/kibana.crt
cp certs/elastic.key certs/kibana.key
cp certs/elastic.crt certs/logstash.crt
cp certs/elastic.key certs/logstash.key

# -------------------------------
# CORRECCION DE PERMISOS
# -------------------------------
echo "[INFO] Ajustando permisos de certificados y claves..."
chown 1000:1000 certs/*.key certs/*.crt
chmod 600 certs/*.key
chmod 644 certs/*.crt

# -------------------------------
# KIBANA CONFIG
# -------------------------------
cat > config/kibana.yml <<EOF
server.host: "0.0.0.0"
server.ssl.enabled: true
server.ssl.certificate: /usr/share/kibana/certs/kibana.crt
server.ssl.key: /usr/share/kibana/certs/kibana.key

elasticsearch.hosts: ["https://elasticsearch:9200"]
elasticsearch.username: kibana_system
elasticsearch.password: ${KIBANA_PASSWORD}
elasticsearch.ssl.verificationMode: none

xpack.encryptedSavedObjects.encryptionKey: "${XPACK_ENCRYPTED_SAVED_OBJECTS_KEY}"
xpack.reporting.encryptionKey: "${XPACK_REPORTING_KEY}"
xpack.security.encryptionKey: "${XPACK_SECURITY_KEY}"
EOF

# -------------------------------
# ENV
# -------------------------------
cat > .env <<EOF
ELASTIC_PASSWORD=${ELASTIC_PASSWORD}
KIBANA_PASSWORD=${KIBANA_PASSWORD}
HOST_IP=${HOST_IP}
EOF

# -------------------------------
# LOGSTASH PIPELINE
# -------------------------------
cat > logstash/pipeline/syslog.conf <<EOF
input { udp { port => 1514 } }
output {
  elasticsearch {
    hosts => ["https://elasticsearch:9200"]
    user => "elastic"
    password => "${ELASTIC_PASSWORD}"
    ssl => true
    ssl_certificate_verification => false
  }
}
EOF

# -------------------------------
# DOCKER COMPOSE
# -------------------------------
cat > docker-compose.yml <<EOF
networks:
  elastic_net:
    driver: bridge

services:
  elasticsearch:
    image: docker.elastic.co/elasticsearch/elasticsearch:8.15.0
    container_name: elasticsearch
    networks: [elastic_net]
    environment:
      discovery.type: single-node
      xpack.security.enabled: "true"
      xpack.security.http.ssl.enabled: "true"
      xpack.security.http.ssl.key: certs/elastic.key
      xpack.security.http.ssl.certificate: certs/elastic.crt
      ELASTIC_PASSWORD: \${ELASTIC_PASSWORD}
    volumes:
      - es_data:/usr/share/elasticsearch/data
      - ./certs:/usr/share/elasticsearch/config/certs
    ports:
      - "\${HOST_IP}:9200:9200"

  kibana:
    image: docker.elastic.co/kibana/kibana:8.15.0
    container_name: kibana
    networks: [elastic_net]
    env_file: .env
    volumes:
      - ./certs:/usr/share/kibana/certs
      - ./config/kibana.yml:/usr/share/kibana/config/kibana.yml
    ports:
      - "\${HOST_IP}:5601:5601"
    depends_on: [elasticsearch]

  logstash:
    image: docker.elastic.co/logstash/logstash:8.15.0
    container_name: logstash
    networks: [elastic_net]
    volumes:
      - ./logstash/pipeline:/usr/share/logstash/pipeline
    depends_on: [elasticsearch]

volumes:
  es_data:
EOF

# -------------------------------
# ARRANQUE
# -------------------------------
docker compose up -d elasticsearch

echo "[INFO] Esperando a que Elasticsearch est  disponible..."
until docker exec elasticsearch curl -sk -u elastic:${ELASTIC_PASSWORD} https://localhost:9200 >/dev/null; do
  sleep 5
done

echo "[INFO] Cambiando password de kibana_system..."
docker exec elasticsearch curl -sk -u elastic:${ELASTIC_PASSWORD} \
  -X POST https://localhost:9200/_security/user/kibana_system/_password \
  -H "Content-Type: application/json" \
  -d "{\"password\":\"${KIBANA_PASSWORD}\"}"

docker compose up -d

echo "[OK] Elastic y Kibana levantados correctamente"
echo "Kibana https://${HOST_IP}:5601"
