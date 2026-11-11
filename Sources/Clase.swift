import Foundation

// MARK: - La carpeta de la materia abierta

/// Dónde vive todo: clases, grabaciones y registros de la materia abierta (Sesion.usar la cambia). Las herramientas de voz
/// y la velocidad al hablar son de la app (Herramientas.carpeta), no de una materia.
enum Carpeta {
    /// La materia que usa la plantilla de oratoria (calentamiento, ronda diaria, pregunta sorpresa), si hay una: ahí se
    /// anota también cómo habló la persona en las demás materias.
    static var oratoria: URL? { Materias.buscar { $0.plantilla == "oratoria" } }
    /// Donde vivía Oratoria antes de que las herramientas fueran de la app (solo para pasarlas una vez).
    static let legado = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Study/Oratoria&Locucion", isDirectory: true)
    /// La materia abierta. Al abrir la app: la de oratoria, o la primera que haya.
    static var raiz: URL = inicial() { didSet { ajustes = Materias.leerAjustes(raiz) } }
    private static var ajustes = Materias.leerAjustes(raiz)
    /// La materia abierta usa la plantilla de oratoria (sus pedidos propios a Claude).
    static var esOratoria: Bool { ajustes.plantilla == "oratoria" }
    /// Antes de su clase va el calentamiento de voz con el afinador.
    static var conCalentamiento: Bool { ajustes.calentamiento ?? esOratoria }
    static func inicial() -> URL { oratoria ?? Materias.todas().first ?? Materias.raiz }
    static func elegirInicial() { raiz = inicial() }
    static var clases: URL { raiz.appendingPathComponent("plan/clases", isDirectory: true) }
    static var grabaciones: URL { raiz.appendingPathComponent("grabaciones", isDirectory: true) }
    static var estados: URL { raiz.appendingPathComponent(".oratoria-app", isDirectory: true) }
    static var progreso: URL { raiz.appendingPathComponent("progreso.md") }
    static var existe: Bool { FileManager.default.fileExists(atPath: raiz.path) }

    static func grabacionesDel(_ fecha: String) -> URL { grabaciones.appendingPathComponent(fecha, isDirectory: true) }

    /// De qué clase son las grabaciones de esa carpeta: su archivo .clase, o "# Respuestas de la clase N" en respuestas.md
    /// (las carpetas de antes). -1 si tiene grabaciones de una clase desconocida; nil si está libre.
    static func duenoDe(_ carpeta: String) -> Int? {
        let dir = grabacionesDel(carpeta)
        if let t = try? String(contentsOf: dir.appendingPathComponent(".clase"), encoding: .utf8),
           let n = Int(t.trimmingCharacters(in: .whitespacesAndNewlines)) { return n }
        if let t = try? String(contentsOf: dir.appendingPathComponent("respuestas.md"), encoding: .utf8),
           let m = t.firstMatch(of: /clase (\d+)/), let n = Int(m.1) { return n }
        let hayWav = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).contains { $0.hasSuffix(".wav") }
        return hayWav ? -1 : nil
    }

    /// La carpeta de grabaciones de una clase que se hace hoy: grabaciones/<hoy>/, o si ya es de otra clase
    /// (dos clases el mismo día), grabaciones/<hoy>-clase-NN/. Así nunca se pisan los mismos nombres de archivo.
    static func carpetaDeHoy(clase n: Int) -> String {
        let hoy = hoy()
        let dueno = duenoDe(hoy)
        return dueno == nil || dueno == n ? hoy : hoy + String(format: "-clase-%02d", n)
    }

    /// Marca la carpeta como de esa clase (al grabar lo primero).
    static func marcar(_ carpeta: String, clase n: Int) {
        let dir = grabacionesDel(carpeta)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? String(n).write(to: dir.appendingPathComponent(".clase"), atomically: true, encoding: .utf8)
    }

    static func hoy() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }
}

// MARK: - Una clase y sus pasos

struct Paso: Identifiable {
    let id: Int
    let titulo: String       // sin los "##"
    let lineas: [String]     // el contenido en Markdown
    /// Nombre corto del paso para los archivos: "Paso 2 · Recordar (5 min)" -> "recordar".
    var slug: String {
        var t = titulo
        if let r = t.range(of: "·") { t = String(t[r.upperBound...]) }
        if let r = t.range(of: "(") { t = String(t[..<r.lowerBound]) }
        let simple = t.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es"))
        let palabras = simple.lowercased().split { !$0.isLetter && !$0.isNumber }.prefix(3)
        return palabras.isEmpty ? "paso-\(id)" : palabras.joined(separator: "-")
    }

    /// Las preguntas se responden hablando: cada número vacío (debajo de "Mis respuestas") y cada "___"
    /// es una grabación. Devuelve la línea donde va y su nombre de archivo, p. ej. "recordar-1".
    var respuestas: [(linea: Int, nombre: String)] {
        var out: [(Int, String)] = []
        var enCodigo = false
        for (i, l) in lineas.enumerated() {
            if l.trimmingCharacters(in: .whitespaces).hasPrefix("```") { enCodigo.toggle() }
            if enCodigo { continue }
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.firstMatch(of: /^\d+\.$/) != nil || t.contains("___") { out.append((i, "\(slug)-\(out.count + 1)")) }
        }
        return out
    }

    /// Las preguntas del paso (los números con texto), para saber qué respondió en cada grabación.
    var preguntas: [String] {
        lineas.compactMap { l in
            let t = l.trimmingCharacters(in: .whitespaces)
            guard let m = t.firstMatch(of: /^\d+\.\s+(.+)$/) else { return nil }
            return String(m.1)
        }
    }

    var grabaciones: [String] {   // nombres de archivo pedidos en este paso, p. ej. "sirena-grave"
        var vistos: [String] = respuestas.map(\.nombre)
        for l in lineas {
            for m in l.matches(of: /`?\d{4}-\d{2}-\d{2}_([A-Za-z0-9\-]+)\.wav`?/) {
                let n = String(m.1)
                if !vistos.contains(n) { vistos.append(n) }
            }
        }
        return vistos
    }
}

struct Clase {
    let numero: Int
    let archivo: URL
    let titulo: String          // la línea "# ..." sin el "#"
    let intro: [String]         // lo que va antes del primer "##"
    let pasos: [Paso]

    var nombreArchivo: String { archivo.lastPathComponent }

    /// "17-oct-2026" -> "17 de octubre" (sin el año), para los títulos.
    static func fechaLegible(_ t: String) -> String {
        let meses = ["ene": "enero", "feb": "febrero", "mar": "marzo", "abr": "abril", "may": "mayo", "jun": "junio",
                     "jul": "julio", "ago": "agosto", "sep": "septiembre", "oct": "octubre", "nov": "noviembre", "dic": "diciembre"]
        return t.replacing(/(\d{1,2})-([a-z]{3})-\d{4}/) { m in
            "\(m.1) de \(meses[String(m.2)] ?? String(m.2))"
        }
    }

    /// Lee el .md y lo parte por secciones "## ". La sección final de respuestas (después de los pasos) se queda como un paso más.
    static func leer(_ url: URL) -> Clase? {
        guard let texto = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let num = Int(url.lastPathComponent.firstMatch(of: /clase-(\d+)/)?.1 ?? "0") ?? 0
        var titulo = "Clase \(num)", intro: [String] = [], pasos: [Paso] = []
        var actual: (String, [String])?
        var enCodigo = false
        for l in texto.components(separatedBy: "\n") {
            if l.hasPrefix("```") { enCodigo.toggle() }
            if !enCodigo && l.hasPrefix("# ") { titulo = Clase.fechaLegible(String(l.dropFirst(2))); continue }
            if !enCodigo && l.hasPrefix("## ") {
                if let a = actual { pasos.append(Paso(id: pasos.count, titulo: a.0, lineas: a.1)) }
                actual = (String(l.dropFirst(3)), [])
                continue
            }
            if actual != nil { actual!.1.append(l) } else { intro.append(l) }
        }
        if let a = actual { pasos.append(Paso(id: pasos.count, titulo: a.0, lineas: a.1)) }
        // quita la línea "---" suelta del final de cada paso
        pasos = pasos.map { p in
            var ls = p.lineas
            while let u = ls.last, u.trimmingCharacters(in: .whitespaces).isEmpty || u.trimmingCharacters(in: .whitespaces) == "---" { ls.removeLast() }
            return Paso(id: p.id, titulo: p.titulo, lineas: ls)
        }
        return Clase(numero: num, archivo: url, titulo: titulo, intro: intro, pasos: pasos)
    }

    /// Todas las clases escritas, en orden.
    static func todas() -> [URL] {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: Carpeta.clases, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.lastPathComponent.hasPrefix("clase-") && $0.pathExtension == "md" }
            .sorted { numeroDe($0) < numeroDe($1) }
    }

    static func numeroDe(_ url: URL) -> Int { Int(url.lastPathComponent.firstMatch(of: /clase-(\d+)/)?.1 ?? "0") ?? 0 }

    /// Días marcados como hechos (✅) en la tabla "Registro diario" de progreso.md.
    static func hechasEnProgreso() -> Set<Int> {
        guard let t = try? String(contentsOf: Carpeta.progreso, encoding: .utf8) else { return [] }
        var hechas = Set<Int>()
        for l in t.components(separatedBy: "\n") where l.hasPrefix("|") && l.contains("✅") {
            let celdas = l.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            if let n = celdas.first.flatMap({ Int($0) }) { hechas.insert(n) }
        }
        return hechas
    }
}

// MARK: - El avance de cada clase (lo que escribes, marcas y grabas)

struct EstadoClase: Codable {
    var fecha: String = Carpeta.hoy()     // carpeta de sus grabaciones: el día de la primera grabación (o <día>-clase-NN)
    var paso = 0
    var calentado = false
    var campos: [String: String] = [:]    // respuestas escritas
    var checks: [String: Bool] = [:]      // casillas
    var notas: [String: String] = [:]     // notas libres por paso
    var autoevaluacion = ""
    var vistos: [Int]? = nil               // pasos leídos hasta el final
    var evaluada = false
    var evaluacion: String?
    var resaltados: [String: [[Int]]]? = nil   // por bloque de texto: rangos [inicio, largo] resaltados
    var grabo: Bool? = nil                 // ya grabó algo de esta clase: desde ahí la fecha (y su carpeta) queda fija

    static func url(_ numero: Int) -> URL { Carpeta.estados.appendingPathComponent(String(format: "clase-%02d.json", numero)) }

    static func cargar(_ numero: Int) -> EstadoClase? {
        guard let d = try? Data(contentsOf: url(numero)) else { return nil }
        return try? JSONDecoder().decode(EstadoClase.self, from: d)
    }

    func guardar(_ numero: Int) {
        try? FileManager.default.createDirectory(at: Carpeta.estados, withIntermediateDirectories: true)
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? e.encode(self).write(to: EstadoClase.url(numero), options: .atomic)
    }
}

/// Qué toca hacer al abrir la app: la primera clase escrita sin terminar, o crear la siguiente.
enum Pendiente {
    case clase(URL)
    case crear(numero: Int, anterior: URL?)

    static func buscar() -> Pendiente {
        let hechas = Clase.hechasEnProgreso()
        let todas = Clase.todas()
        for url in todas {
            let n = Clase.numeroDe(url)
            let evaluada = EstadoClase.cargar(n)?.evaluada ?? false
            if !evaluada && !hechas.contains(n) { return .clase(url) }
        }
        return .crear(numero: (todas.last.map(Clase.numeroDe) ?? 0) + 1, anterior: todas.last)
    }
}
