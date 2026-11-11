import Foundation

// MARK: - Clases de cualquier materia (Oratoria tiene sus propios pedidos en Oratoria.swift)

extension Sesion {
    /// Abre una materia: desde aquí, clases, grabaciones y estados son los de su carpeta. No se cambia de materia mientras
    /// Claude trabaja en otra (su resultado se cargaría en la que esté abierta).
    @discardableResult
    func usar(_ materia: URL) -> Bool {
        if Carpeta.raiz.standardizedFileURL == materia.standardizedFileURL { return true }
        guard trabajando == nil else {
            aviso = "Claude todavía está trabajando en la otra materia. Espera a que termine para cambiar."
            return false
        }
        grabador.detener()
        Carpeta.raiz = materia
        registro = []
        aviso = nil
        recargar()
        return true
    }

    var nombreMateria: String { Materia(url: Carpeta.raiz, ajustes: Materias.leerAjustes(Carpeta.raiz), tienePlan: true, clases: 0).nombre }

    /// Las preguntas que ya se hicieron en las clases de esta materia: para no repetirlas.
    func preguntasPrevias() -> String {
        let lineas = Clase.todas().flatMap { u -> [String] in
            ((try? String(contentsOf: u, encoding: .utf8)) ?? "").components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasSuffix("?") && $0.count > 12 }
        }
        let ultimas = lineas.suffix(200)
        return ultimas.isEmpty ? "" : "\n\n===== Preguntas que ya se hicieron (no las repitas) =====\n" + ultimas.joined(separator: "\n")
    }

    func pedidoDeClaseGeneral(numero n: Int, anterior: URL?, nombre: String, hoy: String) -> String {
        let a = Materias.leerAjustes(Carpeta.raiz)
        let audio = max(5, a.duracion / 3)
        var anexos = ""
        func anexar(_ ruta: String, _ u: URL) {
            guard let t = try? String(contentsOf: u, encoding: .utf8), !t.isEmpty else { return }
            anexos += "\n\n===== \(ruta) =====\n\(t.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        anexar("plan/PLAN.md", Carpeta.raiz.appendingPathComponent("plan/PLAN.md"))
        anexar("aprendido.md (lo que ya se enseñó)", Carpeta.raiz.appendingPathComponent("aprendido.md"))
        anexar("plan/proxima-clase.md", Carpeta.raiz.appendingPathComponent("plan/proxima-clase.md"))
        if let u = anterior { anexar("plan/clases/\(u.lastPathComponent) (la clase anterior)", u) }
        anexar("progreso.md", Carpeta.progreso)
        anexar("cuaderno-de-errores.md", Carpeta.raiz.appendingPathComponent("cuaderno-de-errores.md"))
        return """
        Prepara la clase \(n) de la materia «\(nombreMateria)» para hoy \(hoy). \(Perfil.trato) estudia esta materia y a la vez practica \
        SIEMPRE la oratoria: todo lo responde hablando y grabando, nunca por escrito.
        Sigue plan/PLAN.md (el tema que sigue; las clases van en orden aunque las fechas se corran) y el CLAUDE.md de esta \
        carpeta. Si el plan indica fuentes (estudios/texto/), busca ahí solo lo que la clase necesita y no inventes datos.
        Guarda la clase en plan/clases/\(nombre).
        Formato (la app lo lee así):
        - Empieza con "# Clase \(n) · <tema>" y cada paso con "## Paso N · Nombre", sin tiempos: la clase no dice cuánto dura.
        - Dura \(a.duracion) minutos de reloj, con \(Int(a.teoria)) % de teoría y \(100 - Int(a.teoria)) % de práctica. El \
        tiempo grabado no es el de la clase (leer, pensar, repetir, tomar agua): entre todas las grabaciones, unos \(audio) \
        minutos de audio como mucho.
        - Los pasos, en orden:
          1. Recordar: 3 preguntas SOLO sobre lo que ya se enseñó en clases anteriores (está en aprendido.md). Nunca \
        preguntes algo que aún no se ha enseñado ni repitas una pregunta ya hecha (van abajo). Si todavía no se ha enseñado \
        nada (primera clase, aprendido.md vacío o sin archivo), este paso no va. Sus respuestas van dentro de \
        <details><summary>Ver respuestas</summary> … </details> justo después de las preguntas.
          2. Lección: concisa y directa, con lo que vas a preguntar y practicar.
          3. Preguntas y práctica, de todo tipo sobre la lección de hoy: abiertas, de aplicar a un caso, de explicar con sus \
        palabras y de opción múltiple (A, B, C, D). En las de opción múltiple pide responder grabando cuál elige y por qué. \
        Ninguna lleva respuestas ni pistas: se evalúan al final.
          4. Explicar: lo de hoy explicado en voz alta como a alguien que no sabe nada del tema (una grabación).
          5. Cerrar: su autoevaluación grabada.
        - Cada grabación se nombra en backticks como `\(hoy)_nombre.wav`. Debajo de "**Mis respuestas:**" va una lista \
        numerada vacía, un número por pregunta (la app pone ahí un botón de grabar). Di "responde en voz alta", nunca \
        "escribe".
        - "Ver respuestas" solo en Recordar. Nada sobre cómo usar la app (qué pulsar, cómo grabar). Sin adelantar la clase \
        siguiente. No preguntes por autores, nombres de estudios ni años: el contenido, por qué pasa y cómo se aplica.
        - Si plan/proxima-clase.md trae ejercicios pendientes, inclúyelos en el paso 3 y después deja ese archivo solo con su \
        encabezado.
        \(Materias.indicaciones(Carpeta.raiz))\
        Responde solo con una línea: el nombre del archivo creado.
        Abajo van el plan, lo que ya se enseñó, la clase anterior y el progreso, ya completos: no los vuelvas a abrir. \
        Escribe la clase con una sola escritura (Write).\(anexos)\(preguntasPrevias())
        """
    }

    func pedidoDeEvaluacionGeneral(_ c: Clase, fecha: String, anexos: String) -> String {
        let ppm = Velocidad.leer()?.palabrasPorMinuto ?? 135
        // solo si hay una materia de oratoria (si no, Claude crearía su carpeta)
        let oratoria = Carpeta.oratoria?.path ?? ""
        let pasoOratoria = Carpeta.oratoria != nil ? """
        8. Oratoria: agrega una fila en \(oratoria)/practica-en-otras-materias.md con | Fecha | Materia | Clase | \
        Muletillas por minuto | Tono (st) | Palabras por minuto | Lo que más hay que trabajar | (créalo con ese encabezado si \
        no existe). Si algo de cómo habla conviene entrenarlo, agrégalo como ejercicio nuevo y completo en \
        \(oratoria)/plan/proxima-clase.md.

        """ : ""
        return """
        \(Perfil.trato) acaba de terminar la clase \(c.numero) de «\(nombreMateria)» (plan/clases/\(c.nombreArchivo)) en su app \
        Estudio. Hoy es \(Carpeta.hoy()).
        En grabaciones/\(fecha)/ están sus grabaciones (WAV), las transcripciones literales (.txt), el análisis de voz \
        (analisis-voz.txt) y respuestas.md, que dice qué pregunta responde cada grabación. Respondió todo HABLANDO.
        Su meta es aprender esta materia y practicar SIEMPRE la oratoria: evalúa cada respuesta en dos partes, QUÉ DIJO y \
        CÓMO LO DIJO.
        1. Su autoevaluación grabada: qué cree él que salió bien y mal.
        2. Contenido: cada respuesta contra la hoja. ¿Acertó? ¿Qué le faltó y qué es lo correcto? En las de opción múltiple, \
        si eligió bien y si su porqué es correcto. No corrijas autores, nombres de estudios ni años.
        3. Cómo habla, como en sus clases de oratoria: estructura e idea central, claridad, muletillas, relleno y duda \
        (cuántas, por minuto, en qué frase y cómo decirla sin ellas), variación del tono (mínimo 2 semitonos), velocidad (su \
        promedio es \(Int(ppm)) palabras por minuto; un 20 % más lento o más rápido está bien) y pausas. Cita sus frases.
        4. Escribe grabaciones/\(fecha)/resumen-del-dia.md: una tabla por grabación (grabación, contenido ✅/❌, tono en \
        semitonos, palabras por minuto, muletillas) y las secciones **Autoevaluación** · **Contenido** · **Cómo hablas** · \
        **Cómo vas** (comparado con el progreso).
        5. En progreso.md agrega o completa la fila de la clase \(c.numero) en la tabla "Registro diario", marcada como \
        hecha (✅). Si el archivo no existe, créalo con "# Progreso" y "## Registro diario" y la tabla \
        | Clase | Fecha | Tema | Contenido | Cómo habla |.
        6. En aprendido.md agrega lo que se enseñó hoy: "## Clase \(c.numero) · <tema>" y viñetas cortas con cada concepto \
        (de ahí salen los repasos de las próximas clases). Si no existe, créalo con "# Lo que ya se enseñó".
        7. Anota en cuaderno-de-errores.md lo que falló de contenido, con el porqué.
        \(pasoOratoria)\
        9. Si hay ejercicios de esta materia que le servirían, agrégalos completos a plan/proxima-clase.md (de esta carpeta).
        \(Materias.indicaciones(Carpeta.raiz))\
        Al final responde SOLO con el mensaje para \(Perfil.trato), en \(Perfil.idioma): la evaluación detallada del contenido y \
        de cómo habla, con números y cómo va. Sin preguntas: no puede responderte aquí.
        Abajo van la hoja, las respuestas, el análisis y las transcripciones: no los vuelvas a abrir.\(anexos)
        """
    }
}
