#!/bin/bash

source .env

# Variables configurables
ES_HOST="$AWS_ELASTICSEARCH_ALB_DNS:9200"
ES_USERNAME="elastic"
ES_PASSWORD="campusdual"
INDEX_SOURCE="url"
INDEX_DEST="feed_items2"
SCROLL_DURATION="10m"
SIZE=10000


# Crear índice en Elasticsearch si no existe
echo "Verificando si el índice existe..."
curl -s -X PUT "$ES_HOST/$INDEX_DEST" \
    -u "$ES_USERNAME:$ES_PASSWORD" \
    -H "Content-Type: application/json" \
    -d '{
          "settings": {
            "number_of_shards": 24,
            "number_of_replicas": 1
          },
          "mappings": {
            "properties": {
              "url": {
                "type": "text"
              },
              "fecha": {
                "type": "date"
              }
            }
          }
        }'

# URL del source
SOURCE_URL="$ES_HOST/$INDEX_SOURCE/_search"

# Obtener los primeros documentos con scroll
response=$(curl -s -X GET "$SOURCE_URL?scroll=$SCROLL_DURATION" -H 'Content-Type: application/json' -d'
{
  "query": {
    "match_all": {}
  },
  "size": '"$SIZE"'
}')

# Extraer el scroll_id de la respuesta
scroll_id=$(echo "$response" | jq -r '._scroll_id')

# Función para procesar los items en paralelo
process_items() {
    local items="$1"
    echo "$items" | jq -r '.hits.hits[]._source.url' | xargs -P 40 -I {} ./app add -server "http://${SW_SERVER}:8080" -cmd "bash -c \"./scripts/process_rss.sh {}\"" -timeout 60
}

# Bucle principal
while true; do
    # Extraer las URLs y procesarlas
    hits=$(echo "$response" | jq '.hits.hits | length')
    
    # Si no hay más documentos, salir del bucle
    if [ "$hits" -eq 0 ]; then
        echo "No hay más documentos, finalizando el scroll."
        break
    fi

    # Procesar las URLs del scroll actual en paralelo
    echo "$response" | process_items &

    # Solicitar la siguiente "página" de resultados usando el scroll_id en segundo plano
    response=$(curl -s -X GET "$ES_HOST/_search/scroll" -H 'Content-Type: application/json' -d'
    {
        "scroll": "'"$SCROLL_DURATION"'",
        "scroll_id": "'"$scroll_id"'"
    }')

    # Extraer el nuevo scroll_id para la próxima iteración
    scroll_id=$(echo "$response" | jq -r '._scroll_id')

done

# Liberar el scroll después de procesar
curl -s -X DELETE "$ES_HOST/_search/scroll" -H 'Content-Type: application/json' -d'
{
  "scroll_id": "'"$scroll_id"'"
}'

echo "Scroll finalizado y recursos liberados."

# Crear snapshot de los índices
curl -s -X PUT "$ES_HOST/_snapshot/efs-repo/snapshot3" -H 'Content-Type: application/json' -d'
{
  "indices": "*", 
  "ignore_unavailable": true,
  "include_global_state": true
}'
