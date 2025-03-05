#!/bin/bash

source .env

ES_USERNAME="elastic"
ES_PASSWORD="campusdual"
INDEX_SOURCE="url"
INDEX_DEST="feed_items2"

# Crear el índice en Elasticsearch
echo "Verificando si el índice existe..."
curl -X PUT "$AWS_ELASTICSEARCH_ALB_DNS:9200/$INDEX_DEST" \
    -u "$ES_USERNAME:$ES_PASSWORD" \
    -H "Content-Type: application/json" \
    -d '{
          "settings": {
            "number_of_shards": 33,
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
SIZE=10000

# Solicitud inicial para obtener los primeros documentos y el scroll_id
response=$(curl -s -X GET "$SOURCE_URL?scroll=$SCROLL_DURATION" -H 'Content-Type: application/json' -d'
{
  "query": {
    "match_all": {}
  },
  "size": '"$SIZE"'
}' | jq '.')

# Extraer el scroll_id de la respuesta
scroll_id=$(echo "$response" | jq -r '._scroll_id')

# Procesar los resultados en lotes
while true; do
  # Extraer las URLs
  urls=$(echo "$response" | jq -r '.hits.hits[]._source.url')

  # Crear un array de listas de 20 URLs
  url_batches=() #array de arrais
  batch=()
  count=0
  for url in $urls; do
    batch+=("$url")
    ((count++))

    if [[ $count -eq 50 ]]; then
      # Cuando tenemos 20 URLs, las añadimos a las listas
      url_batches+=("${batch[@]}")
      batch=()  # Limpiar el lote
      count=0
    fi
  done

  # Si quedan menos de 20 URLs, agregarlas al último lote
  if [[ ${#batch[@]} -gt 0 ]]; then
    url_batches+=("${batch[@]}")
  fi

  # Ahora procesamos las listas de 20 URLs por separado
  for batch in "${url_batches[@]}"; do
    echo "Procesando lote de ${#batch[@]} URLs"
    url_batch_str=$(IFS=,; echo "${batch[*]}")
    # Enviar la lista de URLs a xargs para que se procesen en paralelo
    printf "$url_batch_str" | xargs -P 30 -I {} ./app add -server http://${SW_SERVER}:8080 -cmd "bash -c \"./scripts/process_rss_batch.sh {}\"" -timeout 140
    #printf "$url_batch_str" | xargs -P 15 -I {} ./process_rss_batch_local.sh {}
  done

  # Verificar si hay más documentos
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

# Realizar snapshot del índice
curl -X PUT "http://$AWS_ELASTICSEARCH_ALB_DNS:9200/_snapshot/efs-repo/snapshotgrande" -H 'Content-Type: application/json' -d'
{
  "indices": "*", 
  "ignore_unavailable": true,
  "include_global_state": true
}'
