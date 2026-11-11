"""Analiza una grabación de voz con Praat (parselmouth) y da métricas para el plan.

Uso:
    herramientas/.venv/bin/python herramientas/analizar_voz.py grabaciones/archivo.wav [más archivos] [--palabras N] [--rango]

--palabras N: si leíste un texto con N palabras conocidas, calcula las palabras por minuto exactas.
              Si el nombre del archivo contiene "referencia", usa 180 (el texto de referencia).
              Sin eso, las estima por sílabas.
--rango:      para la prueba de la sirena: da tu nota más grave y la más aguda.

Acepta .wav directamente; otros formatos (.mp3, .m4a, .aup3 exportado) se convierten con ffmpeg.
"""
import argparse
import math
import os
import subprocess
import sys
import tempfile

import numpy as np
import parselmouth
from parselmouth.praat import call

SILENCIO_DB = -25        # umbral respecto al máximo para considerar silencio
PAUSA_MIN = 0.25         # segundos: silencios más cortos no cuentan como pausa
PAUSA_MAX = 2.0          # segundos: silencios más largos son cortes entre tomas, no pausas al hablar
SILABAS_POR_PALABRA = 1.95  # promedio medido en español (texto de referencia: 351 sílabas / 180 palabras)


def a_wav(ruta):
    if ruta.lower().endswith(".wav"):
        return ruta, None
    tmp = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
    tmp.close()
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", ruta, "-ac", "1", tmp.name], check=True)
    return tmp.name, tmp.name


def semitonos(f, ref):
    return 12 * np.log2(f / ref)


def nucleos_silabicos(snd, intensidad, pitch):
    """Cuenta núcleos silábicos (picos de intensidad con voz), al estilo de De Jong y Wempe (2009)."""
    t = intensidad.xs()
    v = intensidad.values[0]
    umbral = np.median(v)
    picos = [i for i in range(1, len(v) - 1) if v[i] > v[i - 1] and v[i] >= v[i + 1] and v[i] > umbral]
    validos, ultimo = [], -1
    for i in picos:
        if ultimo >= 0:
            valle = v[ultimo:i].min()
            if v[i] - valle < 2:  # dB: el pico debe sobresalir del valle anterior
                if v[i] > v[ultimo]:
                    validos[-1] = i
                    ultimo = i
                continue
        f0 = pitch.get_value_at_time(t[i])
        if f0 and not math.isnan(f0):
            validos.append(i)
            ultimo = i
    return len(validos)


NOTAS = ["do", "do#", "re", "re#", "mi", "fa", "fa#", "sol", "sol#", "la", "la#", "si"]


def nota(hz):
    m = round(69 + 12 * math.log2(hz / 440))
    return f"{NOTAS[m % 12]}{m // 12 - 1}"


def rango(archivo):
    wav, borrar = a_wav(archivo)
    snd = parselmouth.Sound(wav)
    if snd.n_channels > 1:
        snd = snd.convert_to_mono()
    f0 = snd.to_pitch_ac(time_step=0.01, pitch_floor=60, pitch_ceiling=800).selected_array["frequency"]
    f0 = f0[f0 > 0]
    bajo, alto = np.percentile(f0, [2, 98])
    print(f"Archivo: {os.path.basename(archivo)}")
    print(f"Nota más grave: {bajo:.0f} Hz ({nota(bajo)}) · más aguda: {alto:.0f} Hz ({nota(alto)}) · "
          f"rango: {semitonos(alto, bajo):.0f} semitonos")
    print("Referencia aproximada de canto: bajo ≈ mi2–mi4 · barítono ≈ la2–la4 · tenor ≈ do3–do5 "
          "(la clasificación real también depende del timbre y de dónde la voz cambia de registro)")
    if borrar:
        os.remove(borrar)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("archivos", nargs="+")
    ap.add_argument("--palabras", type=int, default=None)
    ap.add_argument("--rango", action="store_true")
    a = ap.parse_args()
    for i, archivo in enumerate(a.archivos):
        if i:
            print()
        if a.rango or "sirena" in os.path.basename(archivo).lower():
            rango(archivo)
            continue
        palabras = a.palabras or (180 if "referencia" in os.path.basename(archivo).lower() else None)
        analizar(archivo, palabras)


def analizar(archivo, palabras):
    wav, borrar = a_wav(archivo)
    snd = parselmouth.Sound(wav)
    if snd.n_channels > 1:
        snd = snd.convert_to_mono()
    dur = snd.get_total_duration()

    pitch = snd.to_pitch_ac(time_step=0.01, pitch_floor=70, pitch_ceiling=400)
    f0 = pitch.selected_array["frequency"]
    f0 = f0[f0 > 0]
    intensidad = snd.to_intensity(minimum_pitch=70)

    tg = call(snd, "To TextGrid (silences)", 70, 0.0, SILENCIO_DB, PAUSA_MIN, 0.1, "silencio", "voz")
    n = call(tg, "Get number of intervals", 1)
    pausas, cortes, habla = [], [], 0.0
    for i in range(1, n + 1):
        ini = call(tg, "Get start time of interval", 1, i)
        fin = call(tg, "Get end time of interval", 1, i)
        etiqueta = call(tg, "Get label of interval", 1, i)
        if etiqueta == "voz":
            habla += fin - ini
        elif 1 < i < n and fin - ini <= PAUSA_MAX:  # silencios internos que no son cortes
            pausas.append(fin - ini)
        elif 1 < i < n:
            cortes.append(fin - ini)

    silabas = nucleos_silabicos(snd, intensidad, pitch)
    tiempo_util = habla + sum(pausas)

    print(f"Archivo: {os.path.basename(archivo)}")
    print(f"Duración: {dur:.1f} s · hablando: {habla:.1f} s · en pausas: {sum(pausas):.1f} s"
          + (f" · cortes ignorados (> {PAUSA_MAX:.0f} s): {len(cortes)}" if cortes else ""))
    if len(f0):
        mediana = float(np.median(f0))
        st = semitonos(f0, mediana)
        p5, p95 = np.percentile(st, [5, 95])
        print(f"Tono medio: {mediana:.0f} Hz")
        print(f"Variación del tono (desviación): {np.std(st):.1f} semitonos  "
              f"[< 2 = monótono · 2–4 = variado · > 4 = muy marcado]")
        print(f"Rango del tono (5–95 %): {p95 - p5:.1f} semitonos")
    print(f"Pausas (≥ {PAUSA_MIN:.2f} s): {len(pausas)} · "
          f"{len(pausas) / (tiempo_util / 60):.0f} por minuto · "
          f"duración media {np.mean(pausas) if pausas else 0:.2f} s")
    if palabras:
        print(f"Velocidad: {palabras / (tiempo_util / 60):.0f} palabras por minuto "
              f"(exacta, {palabras} palabras) · meta 160–180")
    else:
        ppm = silabas / SILABAS_POR_PALABRA / (tiempo_util / 60)
        print(f"Velocidad estimada: ≈ {ppm:.0f} palabras por minuto ({silabas / habla:.1f} sílabas/s al hablar) "
              f"· meta 160–180 · es una estimación")
    if borrar:
        os.remove(borrar)


if __name__ == "__main__":
    sys.exit(main())
