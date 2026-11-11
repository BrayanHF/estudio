"""Da una pregunta sorpresa al azar para improvisar (sin repetir hasta agotar la lista).

Uso:
    python3 herramientas/pregunta_sorpresa.py
"""
import os
import random

AQUI = os.path.dirname(os.path.abspath(__file__))
BANCO = os.path.join(AQUI, "preguntas-sorpresa.txt")
USADAS = os.path.join(AQUI, ".preguntas-usadas.txt")

with open(BANCO, encoding="utf-8") as f:
    preguntas = [l.strip() for l in f if l.strip() and not l.startswith("#")]
usadas = set()
if os.path.exists(USADAS):
    with open(USADAS, encoding="utf-8") as f:
        usadas = {l.strip() for l in f}
libres = [p for p in preguntas if p not in usadas] or preguntas
if len(libres) == len(preguntas):
    usadas = set()
p = random.choice(libres)
with open(USADAS, "w" if not usadas else "a", encoding="utf-8") as f:
    f.write(p + "\n")
print("\n  " + p + "\n")
print("  Tienes 10 segundos para pensar. Luego graba 1 minuto con PREP: Punto · Razón · Ejemplo · Punto.\n")
