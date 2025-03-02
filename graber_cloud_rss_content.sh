#!/bin/bash

source .env 

#ES_HOST="localhost:9200" # aqui configura la ip privada de tu wsl o lo que sea que uses, tambien la linea 82 o cerca de ahi
ES_USERNAME="elastic"
ES_PASSWORD="campusdual"
INDEX_SOURCE="url"
INDEX_DEST="feed_items"
#INDEX_NAME="url_content"

echo "Verificando si el índice existe..."
curl -X PUT "$AWS_ELASTICSEARCH_ALB_DNS:9200/$INDEX_DEST" \
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




SOURCE_URL="http://$AWS_ELASTICSEARCH_ALB_DNS:9200/$INDEX_SOURCE/_search"


# Duración del scroll
SCROLL_DURATION="30m"

# Tamaño de los resultados por solicitud
SIZE=5000

# Solicitud inicial para obtener los primeros documentos y el scroll_id
response=$(curl -s -X GET "$SOURCE_URL?scroll=$SCROLL_DURATION" -H 'Content-Type: application/json' -d'
{
  "query": {
    "match_all": {}
  },
  "size": '"$SIZE"'
}' | jq '.')

# Extraer el scroll_id de la respuesta


# Procesar los resultados
while true; do
  scroll_id=$(echo "$response" | jq -r '._scroll_id')

  echo "$response" | jq -r '.hits.hits[]._source.url' | xargs -P 50 -I {} ./app add -server http://${SW_SERVER}:8080 -cmd "bash -c \"./scripts/process_rss.sh {}\"" -timeout 120
   

  hits=$(echo "$response" | jq '.hits.hits | length')
  
  if [ "$hits" -eq 0 ]; then
    echo "No hay más documentos, finalizando el scroll."
    break
  fi

  # Solicitar la siguiente "página" de resultados usando el scroll_id
  response=$(curl -s -X GET "http://$AWS_ELASTICSEARCH_ALB_DNS:9200/_search/scroll" -H 'Content-Type: application/json' -d'
  {
    "scroll": "'"$SCROLL_DURATION"'",
    "scroll_id": "'"$scroll_id"'"
  }' | jq '.')

  # Extraer el nuevo scroll_id para la próxima iteración
  scroll_id=$(echo "$response" | jq -r '._scroll_id')
done

# Liberar el scroll al final del proceso
curl -s -X DELETE "http://$AWS_ELASTICSEARCH_ALB_DNS:9200/_search/scroll" -H 'Content-Type: application/json' -d'
{
  "scroll_id": "'"$scroll_id"'"
}'
echo "Scroll finalizado y recursos liberados."
