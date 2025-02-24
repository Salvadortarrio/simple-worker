#!/bin/bash
ES_HOST="172.20.178.149:9200" # aqui configura la ip privada de tu wsl o lo que sea que uses, tambien la linea 82 o cerca de ahi
ES_USERNAME="elastic"
ES_PASSWORD="campusdual"
INDEX_NAME="url_content"

echo "Verificando si el índice existe..."
curl -X PUT "$ES_HOST/$INDEX_NAME" \
    -u "$ES_USERNAME:$ES_PASSWORD" \
    -H "Content-Type: application/json" \
    -d '{
          "settings": {
            "number_of_shards": 3,
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




SOURCE_URL="http://$ES_HOST/url/_search"
DEST_URL="http://$ES_HOST/$INDEX_NAME"

# Duración del scroll
SCROLL_DURATION="30m"

# Tamaño de los resultados por solicitud
SIZE=300

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
  # Imprimir los resultados actuales
  #echo "$response" | jq '.hits.hits'
  #urls=$(echo "$response" | jq -r '.hits.hits[]._source.url') 
  echo "$response" | jq -r '.hits.hits[]._source.url' | xargs -I {} -P 5 ./app add -timeout 20 -cmd '
   # Obtener el código HTTP con curl
   http_code=$(curl -s -o /dev/null -w "%{http_code}" "{}")
   
   # Depuración: mostrar el valor de http_code
   #echo "Código HTTP para {}: \$http_code"

   # Verificar si el código HTTP está en el rango 2XX
   if [[ "$http_code" =~ ^[0-9]+$ ]]; then
     if [ "$http_code" -ge 400 ] && [ "$http_code" -lt 600 ]; then
       # Mostrar el error cuando hay un código 4xx o 5xx
       echo "URL no válida o error al obtener el RSS: {} (Código HTTP: $http_code)"
     else
       # Obtener el contenido RSS usando curl
      # Obtener el contenido RSS usando curl
      rss_content=$(curl -s "{}")

      # Asegurarse de que el contenido RSS esté correctamente escapado para ser parte de un JSON
      rss_content_escaped=$(echo "$rss_content" | jq -Rs .)

      # Crear el cuerpo de la solicitud JSON
      json_data="{\"rss_content\": $rss_content_escaped, \"url\": \"{}\"}"

      echo "$json_data" > /tmp/json_data.json

      # URL de Elasticsearch
      url_with_auth="http://172.20.178.149:9200/url_content/_doc"

      #echo "Antes de enviar el contenido a Elasticsearch"

      # Enviar el contenido RSS a Elasticsearch usando curl con POST y encabezado de autenticación
 # Guardar el resultado en una variable
      response=$(curl  -X POST "$url_with_auth" \
          -H "Content-Type: application/json" \
          -u "elastic:campusdual" \
          -d @/tmp/json_data.json)

      # Imprimir el contenido de la variable
      echo "Respuesta: $response"


     fi
   else
     echo "Error: No se pudo obtener el código HTTP para {}."
   fi
'

  hits=$(echo "$response" | jq '.hits.hits | length')
  
  if [ "$hits" -eq 0 ]; then
    echo "No hay más documentos, finalizando el scroll."
    break
  fi

  # Solicitar la siguiente "página" de resultados usando el scroll_id
  response=$(curl -s -X GET "http://$ES_HOST/_search/scroll" -H 'Content-Type: application/json' -d'
  {
    "scroll": "'"$SCROLL_DURATION"'",
    "scroll_id": "'"$scroll_id"'"
  }' | jq '.')

  # Extraer el nuevo scroll_id para la próxima iteración
  scroll_id=$(echo "$response" | jq -r '._scroll_id')
done

# Liberar el scroll al final del proceso
curl -s -X DELETE "http://$ES_HOST/_search/scroll" -H 'Content-Type: application/json' -d'
{
  "scroll_id": "'"$scroll_id"'"
}'
echo "Scroll finalizado y recursos liberados."



