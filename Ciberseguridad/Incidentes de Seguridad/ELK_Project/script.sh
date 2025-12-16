#!/bin/bash
set -e

echo "==============================================="
echo " Configuracion SEGURA de Elastic Stack (HTTPS)"
echo " Elasticsearch + Kibana + Logstash 8.x"
echo "==============================================="

# ---------------------------------------------
# 0) IP DEL SERVIDOR
# ---------------------------------------------
read -p "Introduce la IP del servidor (obligatoria): " HOST_IP
if [ -z "$HOST_IP" ]; then
  echo "ERROR: La IP es obligatoria"
  exit 1
fi

# ---------------------------------------------
# 1) Contraseña
# ---------------------------------------------
read -s -p "Contraseña para el usuario 'elastic': " ELASTIC_PASSWORD
echo
read -p "Usuario para Kibana: " KIBANA_USER
read -s -p "Contraseña para el usuario Kibana: " KIBANA_PASSWORD
echo

# ---------------------------------------------
# 2) DATOS CERTIFICADO SSL
# ---------------------------------------------
echo "Datos del certificado SSL autofirmado"
read -p "Nombre comun (CN) [ej: elastic.local]: " CERT_CN
read -p "Organizacion (O): " CERT_O
read -p "Pais (C) [ES]: " CERT_C
CERT_C=${CERT_C:-ES}

mkdir -p certs

# ---------------------------------------------
# 3) GENERAR CERTIFICADOS
# ---------------------------------------------
echo "Generando certificado SSL autofirmado..."

openssl req -x509 -newkey rsa:4096 -nodes -days 365 \
  -keyout certs/elastic.key \
  -out certs/elastic.crt \
  -subj "/CN=${CERT_CN}/O=${CERT_O}/C=${CERT_C}" \
  -addext "subjectAltName=IP:${HOST_IP}"

# Reutilizar certificado
cp certs/elastic.crt certs/kibana.crt
cp certs/elastic.key certs/kibana.key
cp certs/elastic.crt certs/logstash.crt
cp certs/elastic.key certs/logstash.key

echo "Certificados creados correctamente"

# ---------------------------------------------
# 4) ARCHIVO .env
# ---------------------------------------------
cat > .env <<EOF
ELASTIC_PASSWORD=${ELASTIC_PASSWORD}
KIBANA_USER=${KIBANA_USER}
KIBANA_PASSWORD=${KIBANA_PASSWORD}
HOST_IP=${HOST_IP}
EOF

# ---------------------------------------------
# 5) docker-compose.yml (HTTPS)
# ---------------------------------------------
cat > docker-compose.yml <<EOF
services:
  elasticsearch:
    image: docker.elastic.co/elasticsearch/elasticsearch:8.15.0
    container_name: elasticsearch
    environment:
      - discovery.type=single-node
      - xpack.security.enabled=true
      - xpack.security.http.ssl.enabled=true
      - xpack.security.http.ssl.key=certs/elastic.key
      - xpack.security.http.ssl.certificate=certs/elastic.crt
      - ELASTIC_PASSWORD=\${ELASTIC_PASSWORD}
    volumes:
      - es_data:/usr/share/elasticsearch/data
      - ./certs:/usr/share/elasticsearch/config/certs
    ports:
      - "\${HOST_IP}:9200:9200"

  kibana:
    image: docker.elastic.co/kibana/kibana:8.15.0
    container_name: kibana
    env_file:
      - .env
    environment:
      - SERVER_HOST=0.0.0.0
      - SERVER_SSL_ENABLED=true
      - SERVER_SSL_CERTIFICATE=/usr/share/kibana/certs/kibana.crt
      - SERVER_SSL_KEY=/usr/share/kibana/certs/kibana.key
      - ELASTICSEARCH_HOSTS=https://\${HOST_IP}:9200
      - ELASTICSEARCH_USERNAME=\${KIBANA_USER}
      - ELASTICSEARCH_PASSWORD=\${KIBANA_PASSWORD}
      - ELASTICSEARCH_SSL_VERIFICATIONMODE=none
    volumes:
      - ./certs:/usr/share/kibana/certs
    ports:
      - "\${HOST_IP}:5601:5601"
    depends_on:
      - elasticsearch

  logstash:
    image: docker.elastic.co/logstash/logstash:8.15.0
    container_name: logstash
    volumes:
      - ./logstash/pipeline:/usr/share/logstash/pipeline
    depends_on:
      - elasticsearch

volumes:
  es_data:
EOF

# ---------------------------------------------
# 6) PIPELINE LOGSTASH HTTPS
# ---------------------------------------------
mkdir -p logstash/pipeline

cat > logstash/pipeline/syslog.conf <<EOF
input {
  udp {
    port => 1514
    type => "syslog"
  }
}

output {
  elasticsearch {
    hosts => ["https://${HOST_IP}:9200"]
    user => "elastic"
    password => "${ELASTIC_PASSWORD}"
    ssl => true
    ssl_certificate_verification => false
    index => "syslog-%{+YYYY.MM.dd}"
  }
}
EOF

# ---------------------------------------------
# 7) ARRANQUE ELASTICSEARCH
# ---------------------------------------------
echo "Arrancando Elasticsearch..."
docker compose up -d elasticsearch

echo "Esperando a que Elasticsearch este disponible..."
until curl -k -u elastic:${ELASTIC_PASSWORD} https://${HOST_IP}:9200 >/dev/null 2>&1; do
  sleep 5
done

# ---------------------------------------------
# 8) CREAR USUARIO KIBANA
# ---------------------------------------------
echo "Creando usuario Kibana..."
docker exec elasticsearch curl -k -u elastic:${ELASTIC_PASSWORD} \
  https://${HOST_IP}:9200/_security/user/${KIBANA_USER} \
  -H "Content-Type: application/json" \
  -X POST -d "{
    \"password\": \"${KIBANA_PASSWORD}\",
    \"roles\": [\"kibana_system\"]
  }"

# ---------------------------------------------
# 9) ARRANCAR TODO
# ---------------------------------------------
docker compose up -d kibana logstash

echo "==============================================="
echo " DESPLIEGUE COMPLETADO CORRECTAMENTE"
echo " Kibana: https://${HOST_IP}:5601"
echo " Certificado autofirmado: acepta el aviso"
echo "==============================================="
