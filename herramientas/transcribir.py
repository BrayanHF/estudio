"""Transcribe grabaciones en español TAL CUAL (localmente) y cuenta muletillas y palabras repetidas.

Uso:
    herramientas/.venv/bin/python herramientas/transcribir.py grabaciones/archivo.wav [más archivos] [opciones]

Modelos (los tres corren en tu Mac, gratis y sin internet):
- por defecto, CrisperWhisper: transcripción literal. Deja repeticiones ("un paquete, un paquete"),
  arranques en falso, sonidos de duda y hasta cómo pronuncias. Es más lento.
- --rapido: Whisper large-v3 (MLX). Más rápido y más "limpio": corrige y quita muletillas.
- --nvidia: Parakeet TDT 0.6B v3 (NVIDIA). Muy rápido; a veces se pasa al inglés.
- --comparar: CrisperWhisper y NVIDIA sobre el mismo audio, uno después del otro.

Opción --tiempos: guarda además el tiempo exacto de cada palabra en ARCHIVO.<modelo>.palabras.tsv
(inicio, fin, palabra), para saber en qué segundo dijiste cada cosa.

Guarda la transcripción junto al audio (ARCHIVO.txt, o ARCHIVO.nvidia.txt / ARCHIVO.rapido.txt).
Aun en modo literal, tu conteo con audífonos es el oficial: ningún modelo oye todos los "eh".
"""
import collections
import os
import re
import sys

os.environ.setdefault("HF_HUB_OFFLINE", "1")  # los modelos ya están descargados
# el idioma de las clases de la persona (lo pone la app Estudio según su perfil); por defecto, español
IDIOMA = os.environ.get("ESTUDIO_IDIOMA", "es")
os.environ.setdefault("HF_HUB_DISABLE_XET", "1")

import numpy as np
import parselmouth
from parselmouth.praat import call

MAX_TROZO = 25.0  # segundos: Whisper trabaja en ventanas de 30 s; cortamos en pausas antes de eso
MULETILLAS = ["eh", "em", "mmm", "mm", "m", "uh", "um", "o sea", "pues", "bueno", "digamos", "como que",
              "lo que es", "tipo", "básicamente", "literal", "literalmente", "la verdad", "obviamente",
              "por así decirlo", "más o menos", "como tal", "lo que sería", "un poquitico"]
# "este" y "entonces" no se cuentan solos: casi siempre son palabras normales ("este video", "entonces llegó").
COLETILLAS = ["¿sí?", "¿no?", "¿cierto?", "¿me entiendes?", "¿ves?"]  # preguntas de muletilla al final
VACIAS = set("""a al algo ante como con de del el ella ellos en entre era es esa ese eso esta este esto
está fue ha hay la las le les lo los me mi mis muy más no nos o para pero por porque que qué se ser si
sí sin sobre son su sus te tiene todo tu tus un una uno unos y ya yo él
también cuando donde hace hacer puede tengo voy van ver vez""".split())


def trozos(snd):
    """Corta el audio en pedazos de ≤ MAX_TROZO segundos, siempre en un silencio."""
    tg = call(snd, "To TextGrid (silences)", 70, 0.0, -25, 0.2, 0.1, "s", "v")
    silencios = []
    for i in range(1, call(tg, "Get number of intervals", 1) + 1):
        if call(tg, "Get label of interval", 1, i) == "s":
            silencios.append((call(tg, "Get start time of interval", 1, i) + call(tg, "Get end time of interval", 1, i)) / 2)
    cortes, ultimo_bueno = [0.0], None
    for m in silencios:
        if m - cortes[-1] > MAX_TROZO and ultimo_bueno:
            cortes.append(ultimo_bueno)
        ultimo_bueno = m
    cortes.append(snd.duration)
    finales = [cortes[0]]
    for c in cortes[1:]:
        while c - finales[-1] > MAX_TROZO + 3:  # trozo largo sin silencios: se parte a la fuerza
            finales.append(finales[-1] + MAX_TROZO)
        finales.append(c)
    return [(a, b) for a, b in zip(finales, finales[1:]) if b - a > 0.3]


_asr = None


def crisper():
    """CrisperWhisper se carga una sola vez y sirve para todos los archivos de la misma corrida."""
    global _asr
    if _asr is None:
        import torch
        from transformers import AutoModelForSpeechSeq2Seq, AutoProcessor, pipeline
        mid, dt = "nyrahealth/CrisperWhisper", torch.float16
        dev = "mps" if torch.backends.mps.is_available() else "cpu"
        modelo = AutoModelForSpeechSeq2Seq.from_pretrained(mid, torch_dtype=dt, low_cpu_mem_usage=True).to(dev)
        proc = AutoProcessor.from_pretrained(mid)
        _asr = pipeline("automatic-speech-recognition", model=modelo, tokenizer=proc.tokenizer,
                        feature_extractor=proc.feature_extractor, torch_dtype=dt, device=dev)
    return _asr


def literal(archivo):
    asr = crisper()
    snd = parselmouth.Sound(archivo).convert_to_mono().resample(16000)
    y = snd.values[0].astype(np.float32)
    salida, palabras = [], []
    for a, b in trozos(snd):
        pedazo = y[int(a * 16000):int(b * 16000)]
        if np.abs(pedazo).max() < 1e-3:
            continue
        # el segundo de cada palabra cuesta tiempo y memoria: solo se calcula si se pide con --tiempos
        extra = {"return_timestamps": "word"} if "--tiempos" in sys.argv else {}
        r = asr({"raw": pedazo, "sampling_rate": 16000}, generate_kwargs={"language": IDIOMA, "task": "transcribe"}, **extra)
        t = r["text"].strip()
        if t:
            salida.append((a, t))
            for c in r.get("chunks", []):
                ini, fin = c["timestamp"]
                palabras.append((a + (ini or 0), a + (fin if fin is not None else (ini or 0)), c["text"].strip()))
    return salida, palabras, snd.duration


def rapido(archivo):
    import mlx_whisper
    pista = "Eh... bueno, este, o sea, eh, mmm, pues... digamos que, ¿sí? Em, como que, lo que es."
    r = mlx_whisper.transcribe(archivo, path_or_hf_repo="mlx-community/whisper-large-v3-mlx", language=IDIOMA,
                               initial_prompt=pista, condition_on_previous_text=False)
    segs = [(s["start"], s["text"].strip()) for s in r["segments"] if s.get("no_speech_prob", 0) < 0.6]
    return segs, [], parselmouth.Sound(archivo).duration


def nvidia(archivo):
    from parakeet_mlx import from_pretrained
    r = from_pretrained("mlx-community/parakeet-tdt-0.6b-v3").transcribe(archivo, chunk_duration=120, overlap_duration=15)
    segs, palabras = [], []
    for frase in r.sentences:
        segs.append((frase.start, frase.text.strip()))
        for tok in frase.tokens:  # los tokens son pedazos de palabra: un espacio inicial marca palabra nueva
            if tok.text.startswith(" ") or not palabras:
                palabras.append([tok.start, tok.end, tok.text.strip()])
            else:
                palabras[-1][1] = tok.end
                palabras[-1][2] += tok.text
    return segs, [tuple(p) for p in palabras], parselmouth.Sound(archivo).duration


def sin_tildes(s):
    return s.translate(str.maketrans("áéíóú", "aeiou"))


def contar(texto):
    t = " " + sin_tildes(re.sub(r"[.,;:!¡¿?…\"\[\]]", " ", texto.lower())) + " "
    muletillas = {m: len(re.findall(rf"(?<=\s){re.escape(sin_tildes(m))}(?=\s)", t)) for m in MULETILLAS}
    muletillas.update({c: texto.lower().count(c) for c in COLETILLAS})
    palabras = re.findall(r"[a-záéíóúüñ]+", texto.lower())
    limpio = " ".join(palabras)
    repeticiones = [m.group(1) for m in re.finditer(r"\b(\w+(?: \w+){0,2}) \1\b", limpio)]  # "un paquete un paquete"
    contenido = collections.Counter(p for p in palabras if p not in VACIAS and len(p) > 2)
    return palabras, {k: v for k, v in muletillas.items() if v}, repeticiones, contenido.most_common(10)


MODELOS = {"literal": (literal, "", "literal (CrisperWhisper)"), "rapido": (rapido, ".rapido", "rápida (Whisper large-v3)"),
           "nvidia": (nvidia, ".nvidia", "NVIDIA (Parakeet TDT 0.6B v3)")}


def main(args):
    if "--comparar" in args:
        modos = ["literal", "nvidia"]
    else:
        modos = ["rapido" if "--rapido" in args else "nvidia" if "--nvidia" in args else "literal"]
    for archivo in [a for a in args if not a.startswith("--")]:
        for modo in modos:
            funcion, sufijo, nombre = MODELOS[modo]
            segs, tiempos, dur = funcion(archivo)
            segs = [(t0, t) for t0, t in segs if not re.search(r"gracias por ver|suscr[ií]bete|subt[ií]tulos", t.lower())]
            lineas = [f"[{int(t0 // 60)}:{t0 % 60:04.1f}] {t}" for t0, t in segs]
            texto = " ".join(t for _, t in segs)
            palabras, muletillas, repeticiones, frecuentes = contar(texto)
            base = os.path.splitext(archivo)[0]
            salida = base + sufijo + ".txt"
            with open(salida, "w", encoding="utf-8") as f:
                f.write(f"# Transcripción {nombre}\n" + "\n".join(lineas) + "\n")
            if "--tiempos" in args and tiempos:
                with open(f"{base}.{modo}.palabras.tsv", "w", encoding="utf-8") as f:
                    f.write("inicio\tfin\tpalabra\n")
                    f.writelines(f"{a:.2f}\t{b:.2f}\t{w}\n" for a, b, w in tiempos)
            total = sum(muletillas.values())
            print(f"=== {os.path.basename(archivo)} · {nombre} → {os.path.basename(salida)}")
            print("\n".join(lineas))
            print(f"\nPalabras: {len(palabras)} · distintas: {len(set(palabras))} "
                  f"({len(set(palabras)) / max(len(palabras), 1) * 100:.0f} % de variedad)")
            print(f"Muletillas detectadas: {total} · {total / (dur / 60):.1f} por minuto · {muletillas}")
            print(f"Repeticiones y arranques en falso: {len(repeticiones)} · {repeticiones[:10]}")
            print(f"Palabras de contenido más repetidas: {frecuentes}")
            if "--tiempos" in args and tiempos:
                print(f"Tiempo de cada palabra: {os.path.basename(base)}.{modo}.palabras.tsv ({len(tiempos)} palabras)")
            print()


if __name__ == "__main__":
    main(sys.argv[1:])
