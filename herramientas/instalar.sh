#!/bin/bash
# Instala las herramientas de voz de Estudio: Python 3.12 (con uv), las librerías y el modelo CrisperWhisper (~3 GB).
# Lo corre la app (botón «Instalar»); también se puede correr a mano. Todo queda en Application Support/Estudio.
set -e
ORIGEN="$(cd "$(dirname "$0")" && pwd)"
DESTINO="$HOME/Library/Application Support/Estudio/herramientas"
mkdir -p "$DESTINO"
echo "1/4 · Copiando los scripts…"
cp "$ORIGEN"/transcribir.py "$ORIGEN"/analizar_voz.py "$ORIGEN"/pregunta_sorpresa.py "$ORIGEN"/preguntas-sorpresa.txt "$DESTINO"/
export PATH="$HOME/.local/bin:$PATH"
if ! command -v uv >/dev/null 2>&1; then
  echo "2/4 · Instalando uv (el instalador de Python)…"
  curl -LsSf https://astral.sh/uv/install.sh | sh
fi
echo "3/4 · Preparando Python 3.12 y las librerías (unos minutos)…"
uv venv --python 3.12 --allow-existing "$DESTINO/.venv"
uv pip install --python "$DESTINO/.venv/bin/python" -r "$ORIGEN/requirements.txt"
echo "4/4 · Descargando el modelo de transcripción (CrisperWhisper, ~3 GB)…"
# ESTUDIO_SIN_MODELO=1: para probar el instalador sin bajar los 3 GB
if [ -z "$ESTUDIO_SIN_MODELO" ]; then
  "$DESTINO/.venv/bin/python" -c "from huggingface_hub import snapshot_download; snapshot_download('nyrahealth/CrisperWhisper')"
fi
echo "LISTO"
