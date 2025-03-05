import requests
import json
import subprocess
import multiprocessing
import os
from time import sleep

ES_USERNAME = "elastic"
ES_PASSWORD = "campusdual"
AWS_ELASTICSEARCH_ALB_DNS = "job-crawler-dev-es-alb-577171025.eu-west-3.elb.amazonaws.com"
SW_SERVER = "51.44.179.46"
INDEX_SOURCE = "url"
INDEX_DEST = "feed_items3"

# URL para las peticiones
SOURCE_URL = f"http://{AWS_ELASTICSEARCH_ALB_DNS}:9200/{INDEX_SOURCE}/_search"
DEST_URL = f"http://{AWS_ELASTICSEARCH_ALB_DNS}:9200/{INDEX_DEST}"

# Duración del scroll
SCROLL_DURATION = "30m"
SIZE = 10000

# Función para crear un índice en Elasticsearch
def create_index():
    url = f"{DEST_URL}"
    data = {
        "settings": {
            "number_of_shards": 33,
            "number_of_replicas": 1
        },
        "mappings": {
            "properties": {
                "url": {"type": "text"},
                "fecha": {"type": "date"}
            }
        }
    }

    response = requests.put(url, auth=(ES_USERNAME, ES_PASSWORD), json=data)
    if response.status_code == 200:
        print(f"Índice '{INDEX_DEST}' creado correctamente.")
    else:
        print(f"Error al crear el índice: {response.text}")

# Función para realizar la solicitud de búsqueda inicial y obtener el primer scroll_id
def initialize_scroll():
    headers = {'Content-Type': 'application/json'}
    query = {
        "query": {"match_all": {}},
        "size": SIZE,
    }

    response = requests.get(SOURCE_URL+f"?scroll={SCROLL_DURATION}", auth=(ES_USERNAME, ES_PASSWORD), headers=headers, json=query)
    response_data = response.json()

    if 'error' in response_data:
        print(f"Error al inicializar el scroll: {response_data['error']}")
        return None

    scroll_id = response_data.get('_scroll_id')
    return scroll_id, response_data

# Función para realizar la solicitud de scroll con un scroll_id
def scroll_through_data(scroll_id):
    headers = {'Content-Type': 'application/json'}
    query = {
        "scroll": SCROLL_DURATION,
        "scroll_id": scroll_id
    }

    response = requests.get(f"http://{AWS_ELASTICSEARCH_ALB_DNS}:9200/_search/scroll", auth=(ES_USERNAME, ES_PASSWORD), headers=headers, json=query)
    return response.json()

# Función para procesar un lote de URLs
def process_batch(batch):
    url_batch_str = ",".join(batch)  # Convertir lista en string separado por comas
    command = [
        './app', 'add', '-server', f'http://{SW_SERVER}:8080',
        '-cmd', f'bash -c "./scripts/process_rss_batch.sh {url_batch_str}"',
        '-timeout', '140'
    ]
    #command = [f'./process_rss_batch_local.sh {url_batch_str}']

    
    # Ejecutar el comando usando subprocess
    try:
        subprocess.run(command, check=True)
        print(f"Procesado lote con {len(batch)} URLs")
    except subprocess.CalledProcessError as e:
        print(f"Error al procesar el lote: {e}")

# Función para procesar las URLs en lotes
def process_batches(urls):
    url_batches = []
    batch = []
    count = 0
    for url in urls:
        batch.append(url)
        count += 1

        if count == 50:
            url_batches.append(batch)
            batch = []
            count = 0

    if batch:
        url_batches.append(batch)

    # Usar multiprocessing para ejecutar los lotes en paralelo
    with multiprocessing.Pool(processes=30) as pool:  # 30 procesos en paralelo
        pool.map(process_batch, url_batches)

# Función para liberar el scroll
def clear_scroll(scroll_id):
    url = f"http://{AWS_ELASTICSEARCH_ALB_DNS}:9200/_search/scroll"
    data = {
        "scroll_id": scroll_id
    }
    response = requests.delete(url, auth=(ES_USERNAME, ES_PASSWORD), json=data)
    if response.status_code == 200:
        print("Scroll liberado correctamente.")
    else:
        print(f"Error al liberar el scroll: {response.text}")

# Función para realizar el snapshot
def create_snapshot():
    snapshot_url = f"http://{AWS_ELASTICSEARCH_ALB_DNS}:9200/_snapshot/efs-repo/snapshotgrande"
    data = {
        "indices": "*",
        "ignore_unavailable": True,
        "include_global_state": True
    }
    response = requests.put(snapshot_url, auth=(ES_USERNAME, ES_PASSWORD), json=data)
    if response.status_code == 200:
        print("Snapshot creado correctamente.")
    else:
        print(f"Error al crear el snapshot: {response.text}")

# Función principal para coordinar el proceso
def main():
    # Crear el índice
    create_index()

    # Inicializar el scroll
    scroll_id, response_data = initialize_scroll()
    if not scroll_id:
        print("No se pudo inicializar el scroll. Abortando el proceso.")
        return

    # Procesar las URLs en lotes mientras haya resultados
    while True:
        # Extraer las URLs
        hits = response_data.get("hits", {}).get("hits", [])
        if not hits:
            print("No hay más documentos, finalizando el scroll.")
            break

        urls = [hit['_source']['url'] for hit in hits]

        # Procesar las URLs en lotes
        process_batches(urls)

        # Obtener el nuevo scroll_id para la siguiente iteración
        scroll_id = response_data.get('_scroll_id')

        # Realizar la siguiente solicitud de scroll
        response_data = scroll_through_data(scroll_id)

        # Hacer una pequeña pausa para evitar demasiadas peticiones seguidas
        sleep(1)

    # Liberar el scroll
    clear_scroll(scroll_id)

    # Crear un snapshot del índice
    create_snapshot()

if __name__ == "__main__":
    main()
