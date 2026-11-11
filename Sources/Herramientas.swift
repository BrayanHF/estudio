import Foundation

/// Corre programas (las herramientas de voz en Python y Claude Code) y va entregando lo que escriben, línea por línea.
enum Herramientas {
    /// Las herramientas de voz (transcribir, analizar la voz, la pregunta sorpresa) son de la app, no de una materia:
    /// sirven para todas y no se van si eliminas Oratoria. Guion también las usa desde aquí.
    static let carpeta = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Estudio/herramientas", isDirectory: true)
    static let python = carpeta.appendingPathComponent(".venv/bin/python").path
    static func script(_ nombre: String) -> String { carpeta.appendingPathComponent(nombre).path }

    /// Antes vivían en la carpeta de Oratoria (herramientas/ y velocidad-al-hablar.json): se pasan una sola vez, al
    /// abrir la app. Es mover, no copiar (mismo disco): el entorno de Python sigue sirviendo porque se llama directo.
    static func migrar() {
        let fm = FileManager.default
        try? fm.createDirectory(at: carpeta.deletingLastPathComponent(), withIntermediateDirectories: true)
        let vieja = Carpeta.legado.appendingPathComponent("herramientas", isDirectory: true)
        if !fm.fileExists(atPath: carpeta.path), fm.fileExists(atPath: vieja.path) { try? fm.moveItem(at: vieja, to: carpeta) }
        let velocidad = Carpeta.legado.appendingPathComponent("velocidad-al-hablar.json")
        if !fm.fileExists(atPath: Velocidad.archivo.path), fm.fileExists(atPath: velocidad.path) {
            try? fm.moveItem(at: velocidad, to: Velocidad.archivo)
        }
    }

    /// Los scripts que trae la app (Resources/herramientas) se copian a la carpeta de las herramientas al abrir: así
    /// siempre están al día. El entorno de Python y los modelos no se tocan (los pone el instalador).
    static func actualizarScripts() {
        guard let origen = Bundle.main.resourceURL?.appendingPathComponent("herramientas") else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: carpeta, withIntermediateDirectories: true)
        for n in ["transcribir.py", "analizar_voz.py", "pregunta_sorpresa.py", "preguntas-sorpresa.txt"] {
            let o = origen.appendingPathComponent(n), d = carpeta.appendingPathComponent(n)
            guard fm.fileExists(atPath: o.path) else { continue }
            // la lista de preguntas sorpresa es de cada persona: solo se pone si no tiene una
            if n == "preguntas-sorpresa.txt", fm.fileExists(atPath: d.path) { continue }
            try? fm.removeItem(at: d)
            try? fm.copyItem(at: o, to: d)
        }
    }

    static var claude: String? {
        let casa = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(casa)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Ejecuta y espera; `linea` recibe la salida a medida que llega (en el hilo principal).
    static func correr(_ programa: String, _ argumentos: [String], alEmpezar: @escaping (Int32) -> Void = { _ in },
                       linea: @escaping (String) -> Void = { _ in }) async -> (codigo: Int32, salida: String) {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: programa)
            p.arguments = argumentos
            // Claude trabaja en la carpeta de la materia (así lee su CLAUDE.md); los scripts de voz, en la suya
            p.currentDirectoryURL = programa == python ? carpeta : Carpeta.raiz
            // prioridad baja: Claude y las transcripciones nunca le quitan CPU al afinador ni a la grabación
            p.qualityOfService = .utility
            var env = ProcessInfo.processInfo.environment
            let casa = FileManager.default.homeDirectoryForCurrentUser.path
            env["PATH"] = "\(casa)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
            env["PYTHONUNBUFFERED"] = "1"
            env["ESTUDIO_IDIOMA"] = Perfil.codigoIdioma   // la transcripción, en el idioma de las clases
            p.environment = env
            p.standardInput = FileHandle.nullDevice   // si no, Claude Code espera 3 s a que le llegue algo por la entrada
            let tubo = Pipe()
            p.standardOutput = tubo; p.standardError = tubo
            var todo = ""
            let lock = NSLock()
            tubo.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
                lock.lock(); todo += s; lock.unlock()
                for l in s.components(separatedBy: "\n") where !l.trimmingCharacters(in: .whitespaces).isEmpty {
                    DispatchQueue.main.async { linea(l) }
                }
            }
            p.terminationHandler = { pr in
                tubo.fileHandleForReading.readabilityHandler = nil
                let resto = tubo.fileHandleForReading.readDataToEndOfFile()
                lock.lock(); todo += String(data: resto, encoding: .utf8) ?? ""; let final = todo; lock.unlock()
                cont.resume(returning: (pr.terminationStatus, final))
            }
            do { try p.run(); alEmpezar(p.processIdentifier) } catch { cont.resume(returning: (-1, "No pude ejecutar \(programa): \(error.localizedDescription)")) }
        }
    }

    /// Mientras Claude crea o evalúa una clase, aquí queda su número de proceso: si la app se cierra y se vuelve a abrir,
    /// espera a ese Claude en vez de lanzar otro (el 28-oct se crearon dos clases a la vez y se gastó el límite).
    static var candadoCrear: URL { Carpeta.raiz.appendingPathComponent("plan/clases/.creando") }
    static var candadoEvaluar: URL { Carpeta.raiz.appendingPathComponent("grabaciones/.evaluando") }

    /// El Claude de ese candado, si sigue vivo.
    static func claudeEnCurso(_ candado: URL) -> Int32? {
        guard let t = try? String(contentsOf: candado, encoding: .utf8), let pid = Int32(t.trimmingCharacters(in: .whitespacesAndNewlines)),
              kill(pid, 0) == 0 else { try? FileManager.default.removeItem(at: candado); return nil }
        return pid
    }

    /// Espera a que termine el Claude que dejó una ventana anterior de la app.
    static func esperar(_ pid: Int32, candado: URL) async {
        while kill(pid, 0) == 0 { try? await Task.sleep(for: .seconds(2)) }
        try? FileManager.default.removeItem(at: candado)
    }

    /// Lo que gasta tokens de más: leer un PDF entero lo manda como imágenes (el 28-oct, 3,6 MB de una tesis) y llena el contexto.
    private static let reglasDeLectura = """
    Para leer los estudios usa los textos de estudios/texto/<nombre>.txt (el texto de cada PDF, con "--- página N ---").     Primero busca con Grep lo que necesitas y lee solo esas partes con offset y limit; nunca leas un .txt largo entero.     Los PDF no se pueden abrir. Si un .txt casi no tiene texto (PDF escaneado), usa lo que dice estudios/README.md de ese estudio.
    """

    /// Le pide algo a Claude Code dentro de la carpeta. Solo puede leer y escribir archivos de ahí.
    /// `web`: también puede buscar y leer páginas en internet (para investigar las fuentes al armar el plan de una materia).
    static func preguntarAClaude(_ pedido: String, candado: URL? = nil, web: Bool = false,
                                 linea: @escaping (String) -> Void = { _ in }) async -> (ok: Bool, respuesta: String) {
        guard let claude else { return (false, "No encontré Claude Code instalado en este Mac.") }
        // fijo para crear clases y para evaluarlas: Opus 5.5 con esfuerzo medio, sin Bash ni PDF
        let herramientas = "Read,Write,Edit,Glob,Grep" + (web ? ",WebSearch,WebFetch" : "")
        let r = await correr(claude, ["-p", pedido, "--model", "claude-opus-5-5", "--effort", "medium", "--permission-mode", "acceptEdits",
                                      "--tools", herramientas, "--allowedTools", herramientas, "--disallowedTools", "Read(**/*.pdf)",
                                      "--strict-mcp-config", "--append-system-prompt", reglasDeLectura + "\n\n" + Perfil.contexto, "--output-format", "text"]
                                      // desde otra materia, Claude también anota en Oratoria cómo hablaste (si existe)
                                      + (Carpeta.oratoria.map { ["--add-dir", $0.path] } ?? []),
                             alEmpezar: { pid in if let candado { try? String(pid).write(to: candado, atomically: true, encoding: .utf8) } },
                             linea: linea)
        if let candado { try? FileManager.default.removeItem(at: candado) }
        let salida = r.salida.trimmingCharacters(in: .whitespacesAndNewlines)
        if salida.contains("Failed to authenticate") || salida.lowercased().contains("please run /login") || salida.contains("Invalid API key") {
            return (false, "Claude Code no tiene la sesión iniciada. Abre la Terminal, escribe claude, inicia sesión con /login y vuelve a intentarlo.")
        }
        return (r.codigo == 0, salida)
    }
}
