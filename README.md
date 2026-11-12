# Estudio

App de Mac para aprender lo que sea con clases diarias hechas a tu medida, respondiendo todo en voz alta: en cada materia practicas también la oratoria. Claude (con tu suscripción) arma el plan de cada materia, prepara la clase de cada día y te evalúa qué dijiste y cómo lo dijiste.

## Instalar

1. **Qué necesitas:** un Mac con Apple Silicon (M1 o más nuevo) y macOS 26, y una suscripción de Claude (Pro o Max): con ella Claude Code arma tus planes, crea tus clases y te evalúa.
2. **Descarga** `Estudio-<versión>.zip` de los [releases](../../releases), descomprímelo y arrastra `Estudio.app` a Aplicaciones.
3. **La primera vez ábrela con clic derecho → Abrir** (no está notarizada por Apple; macOS pregunta una sola vez).
4. **Cuéntale quién eres:** nombre, a qué te dedicas, qué quieres lograr y el idioma de tus clases.
5. **«Antes de empezar»:** instala desde la app lo que falte: Claude Code (e inicia sesión con tu cuenta de Claude en la Terminal que se abre) y las herramientas de voz (~5 GB, una sola vez).
6. **Crea tu primera materia** con «+ Materia nueva». Después, la clase de cada día se prepara sola al tocar la materia.

## Cómo funciona

- **Perfil:** lo que contaste la primera vez (`~/Library/Application Support/Estudio/perfil.json`). Claude lo recibe en cada pedido. Se cambia desde «Tu perfil».
- **Materias:** cada carpeta dentro de tu carpeta de materias es una materia, con su `CLAUDE.md` (qué quieres aprender y cómo enseñarte), su plan (`plan/PLAN.md`), sus clases (`plan/clases/`), las transcripciones de tus respuestas y sus registros (`progreso.md`, `aprendido.md`, `cuaderno-de-errores.md`).
- **Materia nueva:** escribes qué quieres aprender y para qué, y puedes agregar tu material (PDF o texto). Claude investiga fuentes confiables, las guarda en `estudios/` y arma el plan: temario por clase, metas y la base de cada tema.
- **Ajustes de cada materia** (`materia.json`): reparto de teoría y práctica, duración de la clase, «cómo se enseña» (tus reglas), nombre, ícono, si lleva calentamiento de voz antes de la clase y `"plantilla": "oratoria"` para una materia de oratoria (ronda diaria, pregunta sorpresa, palabra del día).
- **Temario:** se edita a mano en la app o pidiéndole el cambio a Claude en palabras.
- **La clase:** repaso de lo que ya se enseñó (nunca de lo que aún no, ni preguntas repetidas), una lección corta, preguntas de todo tipo (también de opción múltiple, diciendo cuál y por qué), explicar el tema y cerrar con tu autoevaluación. Todo se responde grabando.
- **La evaluación:** cada respuesta se transcribe y se analiza la voz, y Claude evalúa el contenido (qué acertaste, qué faltó y lo correcto) y cómo hablaste (estructura, claridad, muletillas, variación del tono, velocidad y pausas). Actualiza tu progreso, lo aprendido y el cuaderno de errores, y deja ejercicios para la próxima clase.
- **Grabaciones:** solo sirven para calificar la clase. Al terminar la evaluación, los audios se borran; quedan las transcripciones, el análisis de voz y el resumen.
- **Velocidad al hablar:** se calcula con tus grabaciones de los últimos 14 días, de todas las materias.
- **Afinador:** calentamiento de voz con piano roll y detección de tono en vivo (CREPE en Core ML o YIN), con evaluación nota a nota.

## Herramientas de voz

Los scripts van dentro de la app (`herramientas/`) y se copian a `~/Library/Application Support/Estudio/herramientas` al abrirla. `instalar.sh` pone uv, Python 3.12, las librerías de `requirements.txt` y el modelo de transcripción literal CrisperWhisper. La transcripción va en el idioma del perfil.

## Compilar

- `./build.sh`: compila `Estudio.app` (solo necesita las Command Line Tools de Xcode) y la copia a `~/Applications`. Si existe el llavero `afinador.keychain-db`, firma con ese certificado para que macOS recuerde el permiso del micrófono entre versiones (se crea con `firma/cert.cnf` y `openssl`); si no, firma de forma provisional.
- `./empaquetar.sh`: arma `dist/Estudio-<versión>.zip` para los releases, con firma genérica.

El código está en `Sources/`: `Materias.swift` y `Contenido.swift` (materias, planes y temario), `ClaseGeneral.swift` y `Oratoria.swift` (clases, evaluación y pantallas), `Perfil.swift`, `Requisitos.swift`, `Herramientas.swift` (Python y Claude Code), `Grabador.swift`, `Afinador.swift` y `Velocidad.swift`.
