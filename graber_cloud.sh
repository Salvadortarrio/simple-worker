#!/bin/bash
source .env
# URL de S3 del archivo comprimido de forma manual
bucket_url="s3://commoncrawl/crawl-data/CC-MAIN-2025-05/wat.paths.gz"

# Nombre del archivo comprimido (no es necesario almacenar el archivo descomprimido)
archivo_comprimido="archivo_descargado.gz"

# Descargar el archivo desde S3 usando AWS CLI y procesar directamente desde el pipe
echo "Descargando y procesando el archivo desde S3: $bucket_url..."

# Usamos `aws s3 cp` para obtener el archivo comprimido y lo descomprimimos directamente en el pipe con `gunzip`
#aws s3 cp "$bucket_url" - | gunzip -c | while IFS= read -r linea; do
  # Pasar cada línea a job.sh (directamente desde el pipe)
#  ./job.sh "$linea"
#done

ES_USERNAME="elastic"
ES_PASSWORD="campusdual"
INDEX_NAME="url"

echo "Verificando si el índice existe..."
curl -X PUT "$AWS_ELASTICSEARCH_ALB_DNS:9200/$INDEX_NAME" \
    -u "$ES_USERNAME:$ES_PASSWORD" \
    -H "Content-Type: application/json" \
    -d '{
          "settings": {
            "number_of_shards": 9,
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


# O si prefieres usar `xargs` para paralelizar
#aws s3 cp "$bucket_url" - | gunzip -c | xargs -I {} -P 1 ./app add -server http://${SW_SERVER}:8080 -cmd "bash -c \"(time ./scripts/job.sh {}) 2>&1 | grep real >> time.txt && aws s3 cp time.txt s3://proyecto-devops-grupo-dos/workers/$(hostname -I | awk '{print $1}') \"" -timeout 100

aws s3 cp "$bucket_url" - | gunzip -c | xargs -I {} -P 20 ./app add -server http://${SW_SERVER}:8080 -cmd "bash -c \"./scripts/job.sh {}\"" -timeout 100

#aws s3 cp "$bucket_url" - | gunzip -c | xargs -I {} -P 1 ./app add -server http://${SW_SERVER}:8080 -cmd " (time sleep 4 )2>&1 | grep real >> time.txt && aws s3 cp time.txt s3://proyecto-devops-grupo-dos/workers/$(hostname -I | awk '{print $1}')/time.txt " -timeout 15

echo "Proceso completado."
