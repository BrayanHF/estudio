import SwiftUI
import AppKit

// MARK: - La sesión del día

enum Pantalla: Equatable { case materias, materia(URL), inicio, calentar, clase, evaluar }

final class Sesion: ObservableObject {
    @Published var pantalla: Pantalla = .materias
    /// El afinador abierto como herramienta (desde las materias), no como calentamiento antes de la clase.
    @Published var soloAfinador = false

    func abrirAfinador() { soloAfinador = true; pantalla = .calentar }
    @Published private(set) var pendiente: Pendiente = .crear(numero: 1, anterior: nil)
    @Published private(set) var clase: Clase?
    @Published var estado = EstadoClase()
    @Published var trabajando: String?        // qué se está haciendo (crear o evaluar), para mostrarlo
    @Published var registro: [String] = []    // lo que van diciendo las herramientas
    @Published var aviso: String?
    @Published var preguntaSorpresa: String?
    // No hay botón de borrar (se borraban grabaciones sin querer): volver a grabar una que ya existe pide confirmación,
    // y la anterior va a la Papelera antes de grabar encima.
    @Published var porRegrabar: String?          // grabación que espera confirmación para regrabarse
    private(set) var candidatoARegrabar: String? // se guarda aparte: el aviso pone porRegrabar en nil al cerrarse
    func pedirRegrabar(_ nombre: String) { candidatoARegrabar = nombre; porRegrabar = nombre }
    func confirmarRegrabar() {
        if let n = candidatoARegrabar {
            borrar(n)
            marcarQueGrabo()
            grabador.grabar(n, fecha: estado.fecha)
        }
        candidatoARegrabar = nil; porRegrabar = nil
    }

    /// Manda la grabación (y su transcripción, si hay) a la Papelera: se puede recuperar.
    func borrar(_ nombre: String) {
        grabador.detener()
        let wav = grabador.url(nombre, fecha: estado.fecha)
        transcriptor.olvidar(wav)
        for u in [wav, wav.deletingPathExtension().appendingPathExtension("txt")] where FileManager.default.fileExists(atPath: u.path) {
            try? FileManager.default.trashItem(at: u, resultingItemURL: nil)
        }
        objectWillChange.send()
    }
    let grabador = Grabador()
    @Published var menuVisible = UserDefaults.standard.object(forKey: "menuVisible") as? Bool ?? true {
        didSet { UserDefaults.standard.set(menuVisible, forKey: "menuVisible") }
    }
    @Published var anchoMenu: CGFloat = UserDefaults.standard.object(forKey: "anchoMenu") as? CGFloat ?? 320 {
        didSet { UserDefaults.standard.set(Double(anchoMenu), forKey: "anchoMenu") }
    }

    func vio(_ paso: Int) -> Bool { estado.vistos?.contains(paso) ?? false }

    /// Todos los pasos leídos hasta el final y todas las grabaciones hechas.
    var claseCompleta: Bool {
        guard let c = clase else { return false }
        return c.pasos.allSatisfy { vio($0.id) } && grabacionesPedidas.allSatisfy { grabador.existe($0, fecha: estado.fecha) }
    }
    func marcarVisto(_ paso: Int) {
        guard !vio(paso) else { return }
        estado.vistos = (estado.vistos ?? []) + [paso]; guardar()
    }

    let transcriptor = Transcriptor()
    init() {
        Herramientas.migrar()
        Herramientas.actualizarScripts()
        recargar()
        Velocidad.actualizar()
        grabador.alEmpezar = { [weak self] in self?.transcriptor.olvidar($0) }
        grabador.alTerminar = { [weak self] in self?.transcriptor.pedir($0) }
        // si cierras la app justo después de escribir, lo último que escribiste no se pierde
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            if self?.esperaGuardar != nil { self?.guardar() }
        }
    }

    func recargar() {
        if esperaGuardar != nil { guardar() }   // lo escrito va a la clase en la que se escribió, antes de cambiar de clase
        // sin materias todavía (la persona aún no crea ninguna): no hay clase que cargar
        if Carpeta.raiz.standardizedFileURL == Materias.raiz.standardizedFileURL {
            clase = nil; estado = EstadoClase(); pendiente = .crear(numero: 1, anterior: nil); aviso = nil; return
        }
        guard Carpeta.existe else { aviso = L("No encuentro la carpeta \(Carpeta.raiz.path)."); return }
        pendiente = Pendiente.buscar()
        if case .clase(let url) = pendiente, let c = Clase.leer(url) {
            clase = c
            estado = EstadoClase.cargar(c.numero) ?? EstadoClase()
            // una clase sin nada grabado todavía se hace hoy, en una carpeta que sea solo suya: grabaciones/<hoy>/, o
            // <hoy>-clase-NN si ya hay otra clase ese día. Si no, sus grabaciones caían en la carpeta de otra clase, que usa
            // los mismos nombres de archivo, y la app las mostraba como propias (pasó con la clase 6 el 29-oct).
            if estado.grabo != true, !estado.evaluada {
                let carpeta = Carpeta.carpetaDeHoy(clase: c.numero)
                if estado.fecha != carpeta { estado.fecha = carpeta; estado.guardar(c.numero) }
            }
            estado.paso = min(estado.paso, max(0, c.pasos.count - 1))
        } else { clase = nil; estado = EstadoClase() }
    }

    private var esperaGuardar: DispatchWorkItem?
    func guardar() {
        esperaGuardar?.cancel(); esperaGuardar = nil
        if let c = clase { estado.guardar(c.numero) }
    }
    /// Lo que escribes se guarda medio segundo después de la última tecla, no con cada tecla.
    private func guardarPronto() {
        esperaGuardar?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.guardar() }
        esperaGuardar = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    /// Desde la primera grabación, la clase se queda con su fecha aunque la termines otro día.
    func marcarQueGrabo() {
        guard estado.grabo != true, let c = clase else { return }
        // por si pasaste la medianoche o se empezó otra clase hoy desde que la abriste
        estado.fecha = Carpeta.carpetaDeHoy(clase: c.numero)
        Carpeta.marcar(estado.fecha, clase: c.numero)
        estado.grabo = true; guardar()
    }

    func empezar() {
        guard clase != nil else { return }
        // el calentamiento de voz es solo antes de Oratoria
        if !Carpeta.conCalentamiento { estado.calentado = true; guardar(); pantalla = .clase; return }
        pantalla = estado.calentado ? .clase : .calentar
    }

    /// Si la clase no existe, se calienta mientras Claude la escribe: al terminar ya está lista y el calentamiento cuenta.
    private var calentoMientrasSeCreaba = false
    func calentarYCrear() {
        calentoMientrasSeCreaba = true
        crearClase()
        pantalla = .calentar
    }

    func terminarCalentamiento() {
        estado.calentado = true; guardar()
        pantalla = .clase
    }

    func ir(aPaso i: Int) {
        guard let c = clase else { return }
        grabador.detener()
        estado.paso = max(0, min(i, c.pasos.count - 1)); guardar()
    }

    // MARK: campos que se escriben y casillas

    func campo(_ clave: String) -> Binding<String> {
        Binding(get: { self.estado.campos[clave] ?? "" }, set: { self.estado.campos[clave] = $0; self.guardarPronto() })
    }
    func check(_ clave: String, inicial: Bool) -> Binding<Bool> {
        Binding(get: { self.estado.checks[clave] ?? inicial }, set: { self.estado.checks[clave] = $0; self.guardar() })
    }
    // MARK: resaltados

    func resaltados(_ clave: String) -> [NSRange] {
        (estado.resaltados?[clave] ?? []).compactMap { $0.count == 2 ? NSRange(location: $0[0], length: $0[1]) : nil }
    }

    /// Si lo seleccionado ya está todo resaltado, se quita; si no, se resalta (uniéndose a lo que toque).
    func alternarResaltado(_ clave: String, _ sel: NSRange) {
        var rangos = resaltados(clave)
        if Sesion.cubre(rangos, sel) {
            rangos = rangos.flatMap { r -> [NSRange] in
                guard let i = r.intersection(sel), i.length > 0 else { return [r] }
                var partes: [NSRange] = []
                if r.location < sel.location { partes.append(NSRange(location: r.location, length: sel.location - r.location)) }
                if NSMaxRange(r) > NSMaxRange(sel) { partes.append(NSRange(location: NSMaxRange(sel), length: NSMaxRange(r) - NSMaxRange(sel))) }
                return partes
            }
        } else {
            var nuevo = sel
            rangos = rangos.filter { r in
                if NSMaxRange(r) >= nuevo.location && r.location <= NSMaxRange(nuevo) { nuevo = NSUnionRange(nuevo, r); return false }
                return true
            }
            rangos.append(nuevo)
        }
        if estado.resaltados == nil { estado.resaltados = [:] }
        estado.resaltados![clave] = rangos.sorted { $0.location < $1.location }.map { [$0.location, $0.length] }
        guardar()
    }

    static func cubre(_ rangos: [NSRange], _ sel: NSRange) -> Bool {
        var pos = sel.location
        for r in rangos.sorted(by: { $0.location < $1.location }) where r.location <= pos && NSMaxRange(r) > pos { pos = NSMaxRange(r) }
        return pos >= NSMaxRange(sel)
    }

    func notas(_ paso: Int) -> Binding<String> {
        Binding(get: { self.estado.notas["\(paso)"] ?? "" }, set: { self.estado.notas["\(paso)"] = $0; self.guardar() })
    }
    var autoevaluacion: Binding<String> {
        Binding(get: { self.estado.autoevaluacion }, set: { self.estado.autoevaluacion = $0; self.guardar() })
    }

    /// Las grabaciones que pide la clase, en orden.
    var grabacionesPedidas: [String] {
        var v: [String] = []
        for p in clase?.pasos ?? [] { for g in p.grabaciones where !v.contains(g) { v.append(g) } }
        return v
    }

    func pedirPreguntaSorpresa() {
        Task { @MainActor in
            let r = await Herramientas.correr("/usr/bin/python3", [Herramientas.script("pregunta_sorpresa.py")])
            preguntaSorpresa = r.salida.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        }
    }

    // MARK: crear la clase que falta

    func crearClase() {
        guard case .crear(let n, let anterior) = pendiente, trabajando == nil else { return }
        // si la app se cerró mientras Claude creaba la clase, ese Claude sigue trabajando: se le espera
        if let pid = Herramientas.claudeEnCurso(Herramientas.candadoCrear) {
            trabajar("Claude ya está creando la clase \(n)…") {
                await Herramientas.esperar(pid, candado: Herramientas.candadoCrear)
                self.recargar()
                if self.calentoMientrasSeCreaba, self.clase != nil { self.estado.calentado = true; self.guardar() }
                self.calentoMientrasSeCreaba = false
            }
            return
        }
        // las demás materias usan el pedido general (ClaseGeneral.swift); Oratoria sigue con el suyo
        if !Carpeta.esOratoria {
            guard FileManager.default.fileExists(atPath: Carpeta.raiz.appendingPathComponent("plan/PLAN.md").path) else {
                aviso = L("Esta materia todavía no tiene plan (plan/PLAN.md). Se arma desde su detalle.")
                return
            }
            let hoy = Carpeta.hoy()
            let nombre = String(format: "clase-%02d-%@.md", n, hoy)
            let pedido = pedidoDeClaseGeneral(numero: n, anterior: anterior, nombre: nombre, hoy: hoy)
            trabajar("Creando la clase \(n) con Claude…") {
                let r = await Herramientas.preguntarAClaude(pedido, candado: Herramientas.candadoCrear) { self.registro.append($0) }
                self.registro.append(r.ok ? L("Listo: \(r.respuesta)") : L("Algo falló: \(r.respuesta)"))
                self.recargar()
            }
            return
        }
        let hoy = Carpeta.hoy()
        let nombre = String(format: "clase-%02d-%@.md", n, hoy)
        let ajustes = Materias.leerAjustes(Carpeta.raiz)
        let pedido = """
        Prepara la clase \(n) del plan para hoy \(hoy). Sigue plan/PLAN.md (el objetivo del día \(n) en la sección 6: \
        \(Perfil.trato) hace las clases en orden, aunque las fechas del plan se corran), CLAUDE.md y el formato exacto de la clase anterior \
        (\(anterior.map { "plan/clases/" + $0.lastPathComponent } ?? "no hay")). Usa los estudios de estudios/ que indica el plan para \
        ese día: busca en sus textos (estudios/texto/) solo lo que la clase necesita y no inventes datos ni cifras. Para el repaso, usa progreso.md, cuaderno-de-errores.md y el último \
        resumen del día (van abajo).
        Guarda la clase en plan/clases/\(nombre).
        \(Perfil.trato) hace la clase dentro de su app Oratoria, así que respeta este formato:
        - Cada paso empieza con "## Paso N · Nombre", sin tiempos: la clase no dice cuánto dura ella ni ningún paso o sección.
        - La clase dura \(ajustes.duracion) MINUTOS DE RELOJ (el calentamiento y cuidado de la voz va aparte, fuera de la \
        clase). Reparto que pidió \(Perfil.trato): \(Int(ajustes.teoria)) % teoría y \(100 - Int(ajustes.teoria)) % práctica. \
        Los pasos, en este orden:
          1. Recordar: 3 preguntas de clases anteriores, sin mirar, con su "Ver respuestas".
          2. Lección: concisa y directa, solo lo que se va a practicar (unas 300 palabras como mucho), leída en voz alta.
          3. Práctica: la mayor parte de la clase. Ejercicios hablados y grabados que apliquen la lección, más la ronda diaria.
          4. Explicar: lo de hoy explicado como si se lo contara a alguien, usando la palabra del día (una grabación corta).
          5. Cerrar: la autoevaluación grabada.
        No va "Intentar antes de leer" (ya no es parte de la clase), aunque la clase anterior lo tenga.
        - El tiempo grabado no es el tiempo de la clase: leer, pensar, repetir una toma, tomar agua o ir al baño también \
        cuentan. Entre todas las grabaciones, la clase no debe pedir más de unos 15 minutos de audio.
        - Nada sobre cómo usar la app (qué pulsar, cómo grabar, dónde escribir): solo el contenido y lo que hay que hacer o responder.
        - Temas muy variados en preguntas, textos e improvisaciones (ciencia, historia, deportes, comida, vida diaria…).
        - Sin adelantar la clase siguiente: nada de "Mañana empiezo con estas preguntas".
        - Nada sobre el miedo a hablar en público (nervios, escalones, exposición): el plan es de comunicación como tal.
        - Nunca preguntes por autores, nombres de estudios ni años ("¿quién hizo el estudio…?", "¿en qué año…?", "¿cómo se \
        llama…?"), ni le pidas citarlos al responder o explicar. \(Perfil.trato) quiere aprender el contenido, no las referencias: \
        pregunta y practica qué se encontró, por qué pasa y cómo se aplica. Para nombrar un hallazgo usa lo que dice \
        ("el estudio de los reclutadores que oyeron o leyeron los discursos"). Los autores solo van en la línea de fuentes del final.
        - Cada aprendizaje que se pueda aplicar lleva su práctica en la clase (un ejercicio hablado), no solo la teoría.
        - Si plan/proxima-clase.md (va abajo) trae ejercicios pendientes, inclúyelos completos en el paso de ejercicios y, \
        después de guardar la clase, deja ese archivo solo con su encabezado.
        \(conteoDeMuletillas() ? """
        - El conteo de muletillas de la ronda diaria (escuchar su grabación y contarlas) va JUSTO DESPUÉS de esa grabación, \
        con su pregunta ("¿cuántas contaste y cuáles?") y su propio "**Mis respuestas:**" ahí mismo, antes del siguiente \
        ejercicio: nunca agrupado en una lista de preguntas más abajo.
        """ : """
        - Hoy NO va el conteo de muletillas en la ronda diaria (ni escuchar la grabación para contarlas, ni preguntar \
        cuántas tuvo): sus últimas 3 clases salieron sin muletillas. Vuelve en cuanto tenga una.
        """)
        - Cualquier pregunta sobre una grabación va justo después de esa grabación, no en una lista más abajo. Fuera del conteo, no nombres muletillas en las instrucciones de los ejercicios ("sin 'eh'", "sin 'simplemente'"): \
        igual se califican en cada grabación.
        - Nunca repitas un ejercicio, texto para leer, trabalenguas o pregunta que ya salió en una clase anterior (abajo van \
        los textos ya usados en todas las clases), aunque \(Perfil.trato) se haya equivocado en él. Para practicar en lo que falló, \
        haz uno nuevo parecido que trabaje justo eso, con otro texto y otro tema. Eso vale también para los de \
        plan/proxima-clase.md: si alguno repite uno ya visto, cámbialo por uno nuevo que trabaje lo mismo.
        - Cada grabación se nombra en backticks como `\(hoy)_nombre.wav`: la app pone el botón de grabar ahí. Nada de Audacity \
        ni comandos de Terminal para grabar, exportar o analizar: al terminar, la app analiza la voz, transcribe y te pide evaluar.
        - \(Perfil.trato) responde TODAS las preguntas hablando, nunca por escrito: se evalúa qué dice y cómo lo dice. Debajo de \
        "**Mis respuestas:**" va una lista numerada vacía, un número por pregunta (la app pone ahí un botón de grabar). Un "___" \
        también se vuelve una grabación. No escribas "escríbelas aquí" ni "responde en el chat": di "responde en voz alta".
        - "Ver respuestas" es SOLO para el paso "Recordar" (el repaso, para ver lo que se le olvidó y repasarlo). Van \
        dentro de <details><summary>Ver respuestas</summary> … </details>, justo después de esas preguntas (la app las \
        bloquea hasta que las grabe). Ningún otro paso lleva "Ver respuestas", ni pistas de respuesta \
        ni respuestas modelo: las preguntas abiertas, los ejercicios y la explicación se evalúan después, al terminar la clase.
        - El calentamiento de voz lo hace la app ANTES de la clase (rutina de canto con afinador): la clase no lleva ningún \
        paso ni instrucción de calentar la voz, ni ejercicios de calentamiento (pitillo, "mmm", vibrar los labios, sirenas, \
        escalas). Si el tema es la voz, se explica la teoría y se practica hablando o leyendo.
        - Para la pregunta sorpresa basta con escribir `python3 herramientas/pregunta_sorpresa.py` en un bloque de código: la app \
        lo convierte en un botón.
        \(Materias.indicaciones(Carpeta.raiz))\
        Responde solo con una línea: el nombre del archivo creado.
        Abajo van PLAN.md, plan/proxima-clase.md, la clase anterior, progreso.md, cuaderno-de-errores.md y el último resumen del día, ya completos:        no los vuelvas a abrir. CLAUDE.md ya lo tienes. Solo te falta buscar en los estudios: haz varias búsquedas a la vez         en un mismo paso y escribe la clase con una sola escritura (Write), sin corregirla después.\(anexosDeClase(anterior))
        """
        trabajar("Creando la clase \(n) con Claude…") {
            let r = await Herramientas.preguntarAClaude(pedido, candado: Herramientas.candadoCrear) { self.registro.append($0) }
            self.registro.append(r.ok ? L("Listo: \(r.respuesta)") : L("Algo falló: \(r.respuesta)"))
            self.recargar()
            if self.calentoMientrasSeCreaba, self.clase != nil { self.estado.calentado = true; self.guardar() }
            self.calentoMientrasSeCreaba = false
        }
    }

    /// Lo que Claude siempre lee para crear la clase va dentro del pedido: cada archivo que abre por su cuenta es otro paso,
    /// y en cada paso vuelve a leer todo lo anterior (así se gastan los tokens).
    private func anexosDeClase(_ anterior: URL?) -> String {
        var anexos = ""
        func anexar(_ ruta: String, _ u: URL) {
            guard let t = try? String(contentsOf: u, encoding: .utf8), !t.isEmpty else { return }
            anexos += "\n\n===== \(ruta) =====\n\(t.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        anexar("plan/PLAN.md", Carpeta.raiz.appendingPathComponent("plan/PLAN.md"))
        anexar("plan/proxima-clase.md", Carpeta.raiz.appendingPathComponent("plan/proxima-clase.md"))
        if let a = anterior { anexar("plan/clases/\(a.lastPathComponent)", a) }
        anexos += usadosEnClases()
        anexar("progreso.md", Carpeta.progreso)
        anexar("cuaderno-de-errores.md", Carpeta.raiz.appendingPathComponent("cuaderno-de-errores.md"))
        // cómo habló en las clases de las demás materias: también es práctica de oratoria
        anexar("practica-en-otras-materias.md", Carpeta.raiz.appendingPathComponent("practica-en-otras-materias.md"))
        let dias = ((try? FileManager.default.contentsOfDirectory(at: Carpeta.grabaciones, includingPropertiesForKeys: nil)) ?? [])
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("resumen-del-dia.md").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if let ultimo = dias.last {
            anexar("grabaciones/\(ultimo.lastPathComponent)/resumen-del-dia.md", ultimo.appendingPathComponent("resumen-del-dia.md"))
        }
        return anexos
    }

    /// El conteo de muletillas de la ronda diaria se quita si las últimas 3 clases evaluadas salieron en 0
    /// (grabaciones/<día>/muletillas.txt, lo escribe la evaluación) y vuelve en cuanto una tenga al menos una.
    private func conteoDeMuletillas() -> Bool {
        let dias = ((try? FileManager.default.contentsOfDirectory(at: Carpeta.grabaciones, includingPropertiesForKeys: nil)) ?? [])
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("resumen-del-dia.md").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }.suffix(3)
        guard dias.count == 3 else { return true }
        return !dias.allSatisfy { d in
            let t = try? String(contentsOf: d.appendingPathComponent("muletillas.txt"), encoding: .utf8)
            return Int(t?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") == 0
        }
    }

    /// Los textos citados (líneas "> ") de todas las clases ya creadas, para que la nueva no repita lecturas ni ejercicios.
    private func usadosEnClases() -> String {
        let clases = ((try? FileManager.default.contentsOfDirectory(at: Carpeta.raiz.appendingPathComponent("plan/clases"),
                                                                     includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var t = ""
        for c in clases {
            guard let texto = try? String(contentsOf: c, encoding: .utf8) else { continue }
            let citas = texto.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("> ") && !$0.hasPrefix("> **Todas") }
            if !citas.isEmpty { t += "\n\(c.lastPathComponent):\n" + citas.joined(separator: "\n") }
        }
        return t.isEmpty ? "" : "\n\n===== Textos ya usados en las clases (no los repitas) =====" + t
    }

    // MARK: evaluar la clase

    func evaluar() {
        guard let c = clase, trabajando == nil else { return }
        grabador.detener()
        let fecha = estado.fecha, dir = Carpeta.grabacionesDel(fecha)
        // si la app se cerró mientras Claude evaluaba, ese Claude sigue: se le espera en vez de pagar otra evaluación.
        // Su respuesta se perdió con la ventana anterior, pero el resumen del día que escribe queda en el disco.
        if let pid = Herramientas.claudeEnCurso(Herramientas.candadoEvaluar) {
            trabajar("Claude ya está evaluando la clase \(c.numero)…") {
                await Herramientas.esperar(pid, candado: Herramientas.candadoEvaluar)
                let resumen = dir.appendingPathComponent("resumen-del-dia.md")
                if let t = try? String(contentsOf: resumen, encoding: .utf8), !t.isEmpty {
                    self.estado.evaluacion = t
                    self.estado.evaluada = true
                    self.guardar()
                    Grabador.borrarAudios(dir)
                } else {
                    self.registro.append(L("La evaluación anterior terminó sin dejar grabaciones/\(fecha)/resumen-del-dia.md. Puedes evaluar de nuevo."))
                }
            }
            return
        }
        trabajar("Evaluando la clase \(c.numero)…") {
            let wavs = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "wav" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            if wavs.isEmpty {
                self.registro.append(L("No hay grabaciones en grabaciones/\(fecha)/: Claude evaluará solo tus respuestas."))
            } else {
                // la voz se analiza al mismo tiempo que se terminan las transcripciones
                self.registro.append(L("1/3 · Analizando la voz de \(wavs.count) grabaciones…"))
                async let analisis = Herramientas.correr(Herramientas.python, [Herramientas.script("analizar_voz.py")] + wavs.map(\.path)) { self.registro.append($0) }
                // casi todas se transcribieron al grabarlas; se espera la que vaya en curso y se hacen las que falten, todas de una
                if self.transcriptor.ocupado { self.registro.append(L("2/3 · Terminando las transcripciones que van en curso…")) }
                await self.transcriptor.esperar()
                let faltan = wavs.filter { Transcriptor.necesita($0) && !FileManager.default.fileExists(atPath: Transcriptor.txt($0).path) }
                if !faltan.isEmpty {
                    self.registro.append(L("2/3 · Transcribiendo \(faltan.count) grabaciones (tarda unos minutos)…"))
                    _ = await Herramientas.correr(Herramientas.python, [Herramientas.script("transcribir.py")] + faltan.map(\.path)) { self.registro.append($0) }
                } else {
                    self.registro.append(L("2/3 · Las transcripciones ya estaban listas."))
                }
                let a = await analisis
                try? a.salida.write(to: dir.appendingPathComponent("analisis-voz.txt"), atomically: true, encoding: .utf8)
            }
            self.escribirRespuestas(c, en: dir)
            self.registro.append(L("3/3 · Claude está revisando la clase…"))
            let pedido = self.pedidoDeEvaluacion(c, fecha: fecha, dir: dir)
            let r = await Herramientas.preguntarAClaude(pedido, candado: Herramientas.candadoEvaluar) { self.registro.append($0) }
            if r.ok && !r.respuesta.isEmpty {
                self.estado.evaluacion = r.respuesta
                self.estado.evaluada = true
                self.guardar()
                Grabador.borrarAudios(dir)   // las grabaciones solo eran para calificar la clase
                Velocidad.actualizar(siempre: true)
            } else {
                self.registro.append(L("Algo falló al evaluar: \(r.respuesta)"))
            }
        }
    }

    /// El pedido lleva dentro la hoja, las respuestas, el análisis y las transcripciones: Claude no tiene que abrirlos uno por uno.
    private func pedidoDeEvaluacion(_ c: Clase, fecha: String, dir: URL) -> String {
        func leer(_ u: URL) -> String? { try? String(contentsOf: u, encoding: .utf8) }
        var anexos = ""
        func anexar(_ ruta: String, _ u: URL) {
            guard let t = leer(u), !t.isEmpty else { return }
            anexos += "\n\n===== \(ruta) =====\n\(t.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        anexar("plan/clases/\(c.nombreArchivo)", c.archivo)
        anexar("grabaciones/\(fecha)/respuestas.md", dir.appendingPathComponent("respuestas.md"))
        anexar("grabaciones/\(fecha)/analisis-voz.txt", dir.appendingPathComponent("analisis-voz.txt"))
        let txts = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "txt" && $0.lastPathComponent != "analisis-voz.txt" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for t in txts { anexar("grabaciones/\(fecha)/\(t.lastPathComponent)", t) }
        // el resumen anterior sirve para comparar cómo va y como modelo de la tabla
        let anteriores = ((try? FileManager.default.contentsOfDirectory(at: Carpeta.grabaciones, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent < fecha && FileManager.default.fileExists(atPath: $0.appendingPathComponent("resumen-del-dia.md").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let anterior = anteriores.last ?? Carpeta.grabaciones.appendingPathComponent("2026-10-16")
        anexar("grabaciones/\(anterior.lastPathComponent)/resumen-del-dia.md (resumen anterior)", anterior.appendingPathComponent("resumen-del-dia.md"))
        if !Carpeta.esOratoria { return pedidoDeEvaluacionGeneral(c, fecha: fecha, anexos: anexos) }
        return """
            \(Perfil.trato) acaba de terminar la clase \(c.numero) (plan/clases/\(c.nombreArchivo)) en su app Oratoria. Hoy es \(Carpeta.hoy()).
            En grabaciones/\(fecha)/ están sus grabaciones (WAV), sus transcripciones literales (.txt, CrisperWhisper), el análisis \
            de voz (analisis-voz.txt) y respuestas.md, que dice qué pregunta responde cada grabación, más sus casillas, notas y su \
            autoevaluación (también grabada). \(Perfil.trato) responde todo HABLANDO: evalúa por lo que dice y por cómo lo dice, no por escrito.
            Lo que \(Perfil.trato) quiere del cierre es una EVALUACIÓN DETALLADA de todo lo que hizo y de cómo va avanzando, no ejercicios.
            1. Empieza por su autoevaluación grabada: qué cree él que salió bien y mal.
            2. Contenido: revisa cada respuesta hablada (recordar, práctica, explicación) contra la hoja. ¿Acertó lo \
            que se encontró, por qué pasa y cómo se aplica? NO evalúes ni corrijas autores, nombres de estudios ni años: no le \
            interesan, solo el contenido.
            3. Cómo habla, en todas las grabaciones: estructura e idea central, claridad y elección de palabras, muletillas y \
            frases encadenadas, concordancia, palabra del día, el aspecto de la semana, y los números del análisis (velocidad, \
            tono, pausas). Cita sus frases literales de las transcripciones como prueba.
               Además de lo que él contó, busca tú las muletillas en cada grabación (también las de leer y repasar) busca en la \
            transcripción literal las muletillas ("eh", "o sea", "pues", "bueno"…), las palabras que sobran (relleno como \
            "simplemente", "realmente", "en verdad", "lo que es", el "y" para encadenar frases) y las de duda ("creo que", \
            "como que", "más o menos", "digamos", repetir o corregir una palabra). Califícalas en cada grabación: cuántas, \
            por minuto, cuáles y en qué frase, y cómo decir esa misma frase sin ellas (una pausa en silencio en vez de la \
            muletilla, empezar directo por la idea, afirmar sin "creo que"). Van en la tabla por grabación y como un aspecto \
            propio ("Muletillas, relleno y duda") en la evaluación por aspecto y en el mensaje final. Compara su conteo con \
            lo que encontraste: cuáles se le escaparon (si hoy no hubo conteo, no lo menciones).
               Escribe también grabaciones/\(fecha)/muletillas.txt con un solo número: el total de muletillas, palabras que \
            sobran y de duda que encontraste en todas las grabaciones del día. La app lo usa para decidir si la próxima clase \
            lleva el conteo: se quita tras 3 clases seguidas en 0 y vuelve con la primera que tenga.
            4. Compara con el resumen anterior y con progreso.md: qué mejoró, qué sigue igual y qué empeoró, con números.
            5. Escribe grabaciones/\(fecha)/resumen-del-dia.md: el encabezado y la tabla por grabación como en el resumen \
            anterior, y después estas secciones (sin sección de "Ejercicio"):
               **Autoevaluación** · **Contenido** (qué acertó, en qué falló y lo correcto) · **Evaluación por aspecto** (cada \
            aspecto del punto 3 con ✅ lo que hace bien, ❌ en qué falló, con su frase, y ➡️ qué hacer distinto) · \
            **Cómo vas** (la comparación del punto 4).
            6. Agrega o completa la fila de la clase \(c.numero) en la tabla "Registro diario" de progreso.md, marcada como hecha (✅).
            7. Anota en cuaderno-de-errores.md lo que falló de contenido o de cómo habla, con el porqué y la fuente (nunca un \
            autor o un año como error).
            8. Si hay ejercicios que le servirían para mejorar, NO se los des aquí: agrégalos a plan/proxima-clase.md (escritos \
            completos, con lo que debe hacer o responder y por qué), para que vayan en la próxima clase. Que sean nuevos: \
            nunca repitas un ejercicio, texto o pregunta que ya hizo, aunque se haya equivocado; haz uno parecido, con otro \
            texto y otro tema, que trabaje justo eso en lo que falló. Si esa clase ya existe \
            en plan/clases/, agrégalos también en su paso de ejercicios.
            No inventes datos: si algo falta (una grabación, un número), dilo.
            \(Materias.indicaciones(Carpeta.raiz))\
            Al final responde SOLO con el mensaje para \(Perfil.trato), en \(Perfil.idioma): la evaluación detallada (cómo le fue con \
            números, contenido, cada aspecto con lo que hace bien, en qué falló y qué hacer distinto, y cómo va frente a las \
            clases anteriores). Sin ejercicios ni tareas, y sin preguntas: no puede responderte aquí.
            Para ir rápido: abajo van ya la hoja de la clase, respuestas.md, el análisis de voz, todas las transcripciones y el \
            resumen anterior. No vuelvas a abrirlos; abre solo lo que vas a editar (progreso.md, cuaderno-de-errores.md, \
            plan/proxima-clase.md) y CLAUDE.md si lo necesitas.\(anexos)
            """
    }

    /// Qué responde cada grabación, lo que marcó y sus notas, para que Claude lo lea.
    private func escribirRespuestas(_ c: Clase, en dir: URL) {
        let fecha = estado.fecha
        var md = "# Respuestas de la clase \(c.numero) · \(fecha)\n\n"
        md += "> \(Perfil.trato) responde hablando: cada respuesta es una grabación (con su transcripción .txt al lado). Se evalúa qué dice y cómo lo dice.\n\n"
        for p in c.pasos {
            var bloque = ""
            let preguntas = p.preguntas
            for (k, r) in p.respuestas.enumerated() {
                let archivo = "\(fecha)_\(r.nombre).wav"
                let hay = Grabador.hay(dir.appendingPathComponent(archivo))
                let linea = p.lineas[r.linea].trimmingCharacters(in: .whitespaces)
                let pregunta = linea.contains("___") ? linea : (k < preguntas.count ? preguntas[k] : "respuesta \(k + 1)")
                bloque += "- **\(pregunta)** → `\(archivo)`\(hay ? "" : " (no la grabó)")\n"
            }
            for (i, l) in p.lineas.enumerated() {
                if let v = estado.checks["p\(p.id)-l\(i)"] {
                    bloque += "- [\(v ? "x" : " ")] \(l.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "- [ ] ", with: ""))\n"
                }
            }
            if let n = estado.notas["\(p.id)"], !n.isEmpty { bloque += "\nNotas escritas: \(n)\n" }
            if !bloque.isEmpty { md += "## \(p.titulo)\n\(bloque)\n" }
        }
        let auto = "\(fecha)_autoevaluacion.wav"
        md += "## Autoevaluación\n"
        md += Grabador.hay(dir.appendingPathComponent(auto)) ? "Grabada en `\(auto)`.\n" : "(no la grabó)\n"
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? md.write(to: dir.appendingPathComponent("respuestas.md"), atomically: true, encoding: .utf8)
    }

    func trabajar(_ titulo: String.LocalizationValue, _ tarea: @escaping @MainActor () async -> Void) {
        trabajando = String(localized: titulo); registro = []
        Task { @MainActor in
            await tarea()
            self.trabajando = nil
        }
    }
}

// MARK: - Transcribir mientras haces la clase

/// Cada grabación se transcribe apenas la paras, en segundo plano y de a una, para que al evaluar no haya que esperar.
final class Transcriptor {
    private var cola: [URL] = []
    private var corriendo = false
    private var esperando: [CheckedContinuation<Void, Never>] = []
    var ocupado: Bool { corriendo || !cola.isEmpty }

    /// La sirena y el silencio no tienen palabras que transcribir.
    static func necesita(_ wav: URL) -> Bool { !["sirena", "silencio"].contains { wav.lastPathComponent.contains($0) } }
    static func txt(_ wav: URL) -> URL { wav.deletingPathExtension().appendingPathExtension("txt") }

    func pedir(_ wav: URL) {
        guard Transcriptor.necesita(wav) else { return }
        cola.removeAll { $0 == wav }; cola.append(wav)
        siguiente()
    }

    /// Se vuelve a grabar o se borra: la transcripción vieja sobra.
    func olvidar(_ wav: URL) {
        cola.removeAll { $0 == wav }
        try? FileManager.default.removeItem(at: Transcriptor.txt(wav))
    }

    private func siguiente() {
        guard !corriendo else { return }
        guard !cola.isEmpty else { esperando.forEach { $0.resume() }; esperando = []; return }
        let wav = cola.removeFirst(), inicio = Date()
        corriendo = true
        Task { @MainActor in
            _ = await Herramientas.correr(Herramientas.python, [Herramientas.script("transcribir.py"), wav.path])
            // si la volviste a grabar mientras se transcribía, el texto es de la versión vieja
            let cambio = (try? wav.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if cambio > inicio { try? FileManager.default.removeItem(at: Transcriptor.txt(wav)) }
            self.corriendo = false
            self.siguiente()
        }
    }

    /// Espera a que se vacíe la cola.
    func esperar() async {
        guard ocupado else { return }
        await withCheckedContinuation { esperando.append($0) }
    }
}

// MARK: - Markdown de las clases, en bloques

indirect enum Bloque {
    case titulo(nivel: Int, texto: String, linea: Int)
    case texto(String, linea: Int)
    case item(nivel: Int, marca: String, texto: String, linea: Int)
    case tarea(nivel: Int, texto: String, marcada: Bool, linea: Int)
    case campo(nivel: Int, marca: String, linea: Int)
    case cita(nivel: Int, texto: String, linea: Int)
    case codigo(String, linea: Int)
    case tabla([[String]], linea: Int)
    case detalles(resumen: String, hijos: [Bloque], linea: Int)
    case regla(linea: Int)

    var linea: Int {
        switch self {
        case .titulo(_, _, let l), .texto(_, let l), .item(_, _, _, let l), .tarea(_, _, _, let l), .campo(_, _, let l),
             .cita(_, _, let l), .codigo(_, let l), .tabla(_, let l), .detalles(_, _, let l), .regla(let l): return l
        }
    }

    static func leer(_ lineas: [String], desde base: Int = 0) -> [Bloque] {
        var out: [Bloque] = []
        var i = 0
        func nivel(_ l: String) -> Int { let s = l.prefix { $0 == " " }.count; return s >= 2 ? (s + 1) / 3 : 0 }
        while i < lineas.count {
            let l = lineas[i], t = l.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { i += 1; continue }
            if t.hasPrefix("```") {
                var cod: [String] = []; i += 1
                while i < lineas.count && !lineas[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") { cod.append(lineas[i].trimmingCharacters(in: .whitespaces)); i += 1 }
                out.append(.codigo(cod.joined(separator: "\n"), linea: base + i)); i += 1; continue
            }
            if t.hasPrefix("<details") {
                let inicio = i; var resumen = L("Ver"); var hijos: [String] = []; i += 1
                while i < lineas.count && !lineas[i].contains("</details>") {
                    if let m = lineas[i].firstMatch(of: /<summary>(.*)<\/summary>/) { resumen = String(m.1) } else { hijos.append(lineas[i]) }
                    i += 1
                }
                out.append(.detalles(resumen: resumen, hijos: leer(hijos, desde: base + inicio + 1), linea: base + inicio)); i += 1; continue
            }
            if t.hasPrefix("|") {
                let inicio = i; var filas: [[String]] = []
                while i < lineas.count && lineas[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    let celdas = lineas[i].trimmingCharacters(in: .whitespaces).dropFirst().dropLast().split(separator: "|", omittingEmptySubsequences: false)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                    if !celdas.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) { filas.append(celdas) }
                    i += 1
                }
                out.append(.tabla(filas, linea: base + inicio)); continue
            }
            if t == "---" { out.append(.regla(linea: base + i)); i += 1; continue }
            // en la clase los ## son los pasos y se leen aparte; aquí llegan los # y ## de la evaluación de Claude
            if let m = t.firstMatch(of: /^(#{1,6})\s+(.*)$/) { out.append(.titulo(nivel: m.1.count, texto: String(m.2), linea: base + i)); i += 1; continue }
            if t.hasPrefix(">") { out.append(.cita(nivel: nivel(l), texto: String(t.dropFirst()).trimmingCharacters(in: .whitespaces), linea: base + i)); i += 1; continue }
            if let m = t.firstMatch(of: /^[-*]\s+\[( |x|X)\]\s*(.*)$/) {
                out.append(.tarea(nivel: nivel(l), texto: String(m.2), marcada: m.1 != " ", linea: base + i)); i += 1; continue
            }
            if let m = t.firstMatch(of: /^([-*]|\d+\.)\s*(.*)$/), t.first != "*" || t.dropFirst().first == " " {
                let marca = m.1 == "-" || m.1 == "*" ? "•" : String(m.1), texto = String(m.2)
                if texto.isEmpty && marca != "•" { out.append(.campo(nivel: nivel(l), marca: marca, linea: base + i)) }
                else { out.append(.item(nivel: nivel(l), marca: marca, texto: texto, linea: base + i)) }
                i += 1; continue
            }
            // párrafo: une las líneas seguidas
            let inicio = i; var p = [t]; i += 1
            while i < lineas.count {
                let s = lineas[i].trimmingCharacters(in: .whitespaces)
                if s.isEmpty || s.hasPrefix("#") || s.hasPrefix(">") || s.hasPrefix("|") || s.hasPrefix("```") || s.hasPrefix("<")
                    || s.firstMatch(of: /^([-*]|\d+\.)(\s|$)/) != nil { break }
                p.append(s); i += 1
            }
            out.append(.texto(p.joined(separator: " "), linea: base + inicio))
        }
        return out
    }
}

// MARK: - Vistas

/// Botón sin borde que se ilumina al pasar el ratón y se hunde un poco al pulsarlo.
struct EstiloHover: ButtonStyle {
    var capsula = false
    /// Margen interno, para botones que son solo texto: sin él el resaltado del hover queda pegado a las letras.
    var margen: CGFloat = 0
    func makeBody(configuration: Configuration) -> some View { ConHover(configuration: configuration, capsula: capsula, margen: margen) }

    // la app se compila con swiftc sin el plugin de macros de SwiftUI: @State no sirve, el estado va en una clase
    final class Estado: ObservableObject { @Published var encima = false }
    struct ConHover: View {
        let configuration: ButtonStyleConfiguration
        var capsula = false
        var margen: CGFloat = 0
        @StateObject private var estado = Estado()
        @Environment(\.isEnabled) private var activo
        var body: some View {
            let forma = RoundedRectangle(cornerRadius: capsula ? 999 : 10)
            configuration.label
                .padding(.horizontal, margen).padding(.vertical, margen * 0.5)
                .background(Color.white.opacity(configuration.isPressed ? 0.16 : (estado.encima && activo ? 0.09 : 0)), in: forma)
                .contentShape(forma)
                .animation(.easeOut(duration: 0.12), value: estado.encima)
                .onHover { if estado.encima != $0 { estado.encima = $0 } }
        }
    }
}

extension ButtonStyle where Self == EstiloHover {
    static var hover: EstiloHover { EstiloHover() }
    static var hoverCapsula: EstiloHover { EstiloHover(capsula: true) }
    /// Botón de solo texto (volver, abrir, saltar…) con su margen, para que el hover no quede pegado. z = zoom de la vista.
    static func enlace(_ z: CGFloat) -> EstiloHover { EstiloHover(margen: 12 * z) }
}

/// Botón que es solo un icono: un círculo lo rodea y es el círculo el que se ilumina al pasar el ratón.
struct EstiloIcono: ButtonStyle {
    var diametro: CGFloat = 34
    func makeBody(configuration: Configuration) -> some View { Circulo(configuration: configuration, diametro: diametro) }

    struct Circulo: View {
        let configuration: ButtonStyleConfiguration
        let diametro: CGFloat
        @StateObject private var estado = EstiloHover.Estado()
        @Environment(\.isEnabled) private var activo
        var body: some View {
            configuration.label
                .frame(width: diametro, height: diametro)
                .background(Circle().fill(Color.white.opacity(configuration.isPressed ? 0.18 : (estado.encima && activo ? 0.1 : 0))))
                .contentShape(Circle())
                .animation(.easeOut(duration: 0.12), value: estado.encima)
                .onHover { if estado.encima != $0 { estado.encima = $0 } }
        }
    }
}

extension ButtonStyle where Self == EstiloIcono {
    static func icono(_ diametro: CGFloat) -> EstiloIcono { EstiloIcono(diametro: diametro) }
}

private extension View {
    func tarjeta(_ z: CGFloat, radio: CGFloat = 20, ancha: Bool = true) -> some View {
        frame(maxWidth: ancha ? .infinity : nil, alignment: .leading)
            .padding(z * 18).glassEffect(.regular, in: RoundedRectangle(cornerRadius: z * radio))
    }
}

/// Texto con negritas, cursivas, código y enlaces de Markdown.
struct TextoMD: View {
    let texto: String
    let z: CGFloat
    var tam: CGFloat = 15
    var peso: Font.Weight = .regular
    var body: some View {
        let limpio = texto.replacingOccurrences(of: "<br>", with: "\n")
        let a = (try? AttributedString(markdown: limpio, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(limpio)
        Text(a).font(.system(size: tam * z, weight: peso)).lineSpacing(6 * z).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Texto de la lección que se puede seleccionar: arriba a la derecha de lo seleccionado sale un botón para resaltarlo
/// (o quitarle el resaltado). Los resaltados se guardan con la clase.
struct TextoResaltable: NSViewRepresentable {
    let texto: String
    let z: CGFloat
    var tam: CGFloat = 15
    var peso: Font.Weight = .regular
    var color: NSColor = .labelColor
    let clave: String
    @ObservedObject var s: Sesion

    static let amarillo = NSColor.systemYellow.withAlphaComponent(0.32)

    func makeCoordinator() -> Coordinador { Coordinador() }

    /// El texto siempre se reparte en el ancho real de la vista (ni más angosto ni más ancho).
    final class Vista: NSTextView {
        override func setFrameSize(_ n: NSSize) {
            super.setFrameSize(n)
            textContainer?.containerSize = NSSize(width: n.width, height: .greatestFiniteMagnitude)
        }
    }

    func makeNSView(context: Context) -> NSTextView {
        let tv = Vista()
        tv.isEditable = false; tv.isSelectable = true; tv.drawsBackground = false; tv.isRichText = true
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = false
        tv.isVerticallyResizable = false; tv.isHorizontallyResizable = false
        tv.delegate = context.coordinator
        return tv
    }

    func updateNSView(_ tv: NSTextView, context: Context) {
        let c = context.coordinator
        c.clave = clave; c.s = s
        let rangos = s.resaltados(clave)
        let firma = "\(texto)|\(tam)|\(z)|\(rangos)"
        guard c.firma != firma else { return }
        c.firma = firma
        tv.textStorage?.setAttributedString(armar(rangos))
    }

    /// Se mide con un diseño aparte (sin tocar la vista), para que el alto sea justo el del ancho que se propone.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView tv: NSTextView, context: Context) -> CGSize? {
        let texto = NSAttributedString(attributedString: tv.textStorage ?? NSTextStorage())
        let fijo = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let usado = TextoResaltable.medir(texto, ancho: fijo ?? 100_000)
        return CGSize(width: fijo ?? ceil(usado.width), height: ceil(usado.height))
    }

    static func medir(_ a: NSAttributedString, ancho: CGFloat) -> CGSize {
        let st = NSTextStorage(attributedString: a), lm = NSLayoutManager()
        let tc = NSTextContainer(size: NSSize(width: ancho, height: .greatestFiniteMagnitude))
        tc.lineFragmentPadding = 0
        lm.addTextContainer(tc); st.addLayoutManager(lm)
        lm.ensureLayout(for: tc)
        return lm.usedRect(for: tc).size
    }

    /// Markdown en línea (negrita, cursiva, código, enlaces) a texto con estilo, más los resaltados.
    private func armar(_ rangos: [NSRange]) -> NSAttributedString {
        let limpio = texto.replacingOccurrences(of: "<br>", with: "\n")
        let a = (try? AttributedString(markdown: limpio, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(limpio)
        let parrafo = NSMutableParagraphStyle(); parrafo.lineSpacing = 6 * z
        let base = NSFont.systemFont(ofSize: tam * z, weight: peso.ns)
        let out = NSMutableAttributedString()
        for run in a.runs {
            let trozo = String(a[run.range].characters)
            var fuente = base
            let intento = run.inlinePresentationIntent ?? []
            if intento.contains(.code) { fuente = .monospacedSystemFont(ofSize: tam * z * 0.92, weight: peso.ns) }
            if intento.contains(.stronglyEmphasized) { fuente = NSFont.systemFont(ofSize: tam * z, weight: .bold) }
            if intento.contains(.emphasized) { fuente = NSFontManager.shared.convert(fuente, toHaveTrait: .italicFontMask) }
            var at: [NSAttributedString.Key: Any] = [.font: fuente, .foregroundColor: color, .paragraphStyle: parrafo]
            if let l = run.link { at[.link] = l }
            out.append(NSAttributedString(string: trozo, attributes: at))
        }
        for r in rangos where NSMaxRange(r) <= out.length { out.addAttribute(.backgroundColor, value: TextoResaltable.amarillo, range: r) }
        return out
    }

    final class Coordinador: NSObject, NSTextViewDelegate {
        var clave = ""
        weak var s: Sesion?
        var firma = ""
        private var popover: NSPopover?
        private var espera: DispatchWorkItem?

        func textViewDidChangeSelection(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            espera?.cancel()
            popover?.close(); popover = nil
            guard tv.selectedRange().length > 0 else { return }
            let w = DispatchWorkItem { [weak self, weak tv] in if let tv { self?.mostrar(tv) } }
            espera = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: w)
        }

        /// El botón sale cuando sueltas el ratón, arriba a la derecha de lo seleccionado.
        private func mostrar(_ tv: NSTextView) {
            guard NSEvent.pressedMouseButtons == 0 else {
                let w = DispatchWorkItem { [weak self, weak tv] in if let tv { self?.mostrar(tv) } }
                espera = w; DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: w); return
            }
            let sel = tv.selectedRange()
            guard sel.length > 0, let s, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            let quitar = Sesion.cubre(s.resaltados(clave), sel)
            // arriba a la derecha del puntero; si no se puede leer, arriba a la derecha de lo seleccionado
            var punto: NSPoint
            if let w = tv.window {
                punto = tv.convert(w.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            } else {
                let r = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: sel, actualCharacterRange: nil), in: tc)
                punto = NSPoint(x: r.maxX, y: r.minY)
            }
            punto.x += 14; punto.y -= 6
            let boton = NSButton(image: NSImage(systemSymbolName: quitar ? "eraser" : "highlighter",
                                                accessibilityDescription: quitar ? L("Quitar resaltado") : L("Resaltar"))!,
                                 target: self, action: #selector(alternar(_:)))
            boton.isBordered = false
            boton.contentTintColor = quitar ? .secondaryLabelColor : .systemYellow
            boton.toolTip = quitar ? L("Quitar el resaltado") : L("Resaltar")
            boton.frame = NSRect(x: 0, y: 0, width: 34, height: 28)
            let vc = NSViewController(); vc.view = NSView(frame: boton.frame); vc.view.addSubview(boton)
            let p = NSPopover(); p.contentViewController = vc; p.behavior = .transient; p.animates = false
            p.show(relativeTo: NSRect(x: punto.x, y: punto.y, width: 2, height: 2), of: tv, preferredEdge: .minY)
            popover = p
            textView = tv
        }

        private weak var textView: NSTextView?

        @objc private func alternar(_ b: NSButton) {
            guard let tv = textView, let s else { return }
            let sel = tv.selectedRange()
            popover?.close(); popover = nil
            guard sel.length > 0 else { return }
            s.alternarResaltado(clave, sel)
            tv.setSelectedRange(NSRange(location: NSMaxRange(sel), length: 0))
        }
    }
}

private extension Font.Weight {
    var ns: NSFont.Weight {
        switch self {
        case .bold: return .bold
        case .semibold: return .semibold
        case .medium: return .medium
        default: return .regular
        }
    }
}

struct VistaBloques: View {
    let bloques: [Bloque]
    let pasoId: Int
    @ObservedObject var s: Sesion
    let z: CGFloat

    var body: some View {
        let (pares, ocultas) = emparejar()
        VStack(alignment: .leading, spacing: 16 * z) {
            ForEach(Array(bloques.enumerated()), id: \.offset) { _, b in
                if !ocultas.contains(b.linea) {
                    if let campo = pares[b.linea], let n = respuesta(campo) {
                        VStack(alignment: .leading, spacing: 10 * z) {
                            vista(b)
                            FilaGrabacion(nombre: n, s: s, g: s.grabador, z: z, titulo: "Responde hablando").padding(.leading, 26 * z)
                        }
                        .padding(.bottom, 6 * z)
                    } else { vista(b) }
                }
            }
        }
    }

    /// Cada pregunta numerada lleva su grabación justo debajo: los números vacíos de "Mis respuestas" se emparejan, en orden,
    /// con las preguntas de antes, y esa lista (con su título) ya no se muestra. Devuelve línea de la pregunta -> línea del número vacío.
    private func emparejar() -> ([Int: Int], Set<Int>) {
        var pares: [Int: Int] = [:], ocultas = Set<Int>()
        var preguntas: [Int] = []
        var i = 0
        while i < bloques.count {
            if case .item(0, let m, _, let l) = bloques[i], m != "•" { preguntas.append(l); i += 1; continue }
            guard case .campo = bloques[i] else { i += 1; continue }
            var campos: [Int] = []
            while i < bloques.count, case .campo(_, _, let l) = bloques[i] { campos.append(l); i += 1 }
            guard preguntas.count >= campos.count else { preguntas = []; continue }
            for (q, c) in zip(preguntas.suffix(campos.count), campos) { pares[q] = c; ocultas.insert(c) }
            // el "**Mis respuestas:**" de encima sobra
            if let j = bloques.firstIndex(where: { $0.linea == campos[0] }), j > 0,
               case .texto(let t, let l) = bloques[j - 1], t.localizedCaseInsensitiveContains("respuestas") { ocultas.insert(l) }
            preguntas = []
        }
        return (pares, ocultas)
    }

    private func clave(_ l: Int) -> String { "p\(pasoId)-l\(l)" }
    /// Los resaltados se guardan por paso y por el texto exacto del bloque.
    private func resaltable(_ t: String) -> String { "p\(pasoId)|\(t)" }

    /// Si el texto nombra una grabación, debajo va su botón de grabar.
    @ViewBuilder private func conGrabacion(_ texto: String, _ contenido: some View) -> some View {
        let nombres = texto.matches(of: /\d{4}-\d{2}-\d{2}_([A-Za-z0-9\-]+)\.wav/).map { String($0.1) }
        VStack(alignment: .leading, spacing: 8 * z) {
            contenido
            ForEach(nombres, id: \.self) { FilaGrabacion(nombre: $0, s: s, g: s.grabador, z: z) }
        }
    }

    /// Un "___" en el texto se responde hablando: debajo va su grabación.
    @ViewBuilder private func conHueco(_ texto: String, linea: Int, _ contenido: some View) -> some View {
        if texto.contains("___"), let n = respuesta(linea) {
            VStack(alignment: .leading, spacing: 6 * z) {
                contenido
                FilaGrabacion(nombre: n, s: s, g: s.grabador, z: z, titulo: "Responde hablando")
            }
        } else { contenido }
    }

    private func respuesta(_ linea: Int) -> String? {
        s.clase?.pasos.first { $0.id == pasoId }?.respuestas.first { $0.linea == linea }?.nombre
    }

    @ViewBuilder private func vista(_ b: Bloque) -> some View {
        switch b {
        case .titulo(let n, let t, _):
            TextoResaltable(texto: t, z: z, tam: n <= 1 ? 24 : n == 2 ? 20 : n == 3 ? 18 : 16, peso: .bold, clave: resaltable(t), s: s).padding(.top, 16 * z)
        case .texto(let t, let l):
            conGrabacion(t, conHueco(t, linea: l, TextoResaltable(texto: t.replacingOccurrences(of: "___", with: "…"), z: z, clave: resaltable(t), s: s)))
        case .item(let n, let m, let t, let l):
            conGrabacion(t, conHueco(t, linea: l, HStack(alignment: .top, spacing: 8 * z) {
                Text(m).font(.system(size: 15 * z, weight: .semibold)).foregroundStyle(.secondary).frame(minWidth: 18 * z, alignment: .trailing)
                TextoResaltable(texto: t.replacingOccurrences(of: "___", with: "…"), z: z, clave: resaltable(t), s: s)
            }.padding(.leading, CGFloat(n) * 22 * z)))
        case .tarea(let n, let t, let marcada, let l):
            Toggle(isOn: s.check(clave(l), inicial: marcada)) { TextoMD(texto: t, z: z) }
                .toggleStyle(.checkbox).padding(.leading, CGFloat(n) * 22 * z)
        case .campo(let n, let m, let l):
            HStack(alignment: .center, spacing: 8 * z) {
                Text(m).font(.system(size: 15 * z, weight: .semibold)).foregroundStyle(.secondary).frame(minWidth: 18 * z, alignment: .trailing)
                if let nombre = respuesta(l) { FilaGrabacion(nombre: nombre, s: s, g: s.grabador, z: z, titulo: L("Respuesta \(String(m.dropLast()))")) }
            }.padding(.leading, CGFloat(n) * 22 * z)
        case .cita(let n, let t, let l):
            conGrabacion(t, conHueco(t, linea: l, HStack(spacing: 10 * z) {
                RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.35)).frame(width: 3 * z)
                TextoResaltable(texto: t.replacingOccurrences(of: "___", with: "…"), z: z, color: NSColor(Color.suave), clave: resaltable(t), s: s)
            }.padding(.leading, CGFloat(n) * 22 * z)))
        case .codigo(let c, _):
            if c.contains("pregunta_sorpresa.py") {
                PreguntaSorpresa(s: s, z: z)
            } else if c.contains("analizar_voz.py") || c.contains("transcribir.py") || c.hasPrefix("cd ") {
                Label("De esto se encarga la app al evaluar la clase.", systemImage: "checkmark.seal").font(.system(size: 13 * z)).foregroundStyle(.secondary)
            } else {
                Text(c).font(.system(size: 13 * z, design: .monospaced)).padding(10 * z)
                    .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8 * z)).textSelection(.enabled)
            }
        case .tabla(let filas, _):
            // sin scroll: las columnas se reparten el ancho y el texto largo baja de línea
            Grid(alignment: .topLeading, horizontalSpacing: 14 * z, verticalSpacing: 8 * z) {
                ForEach(Array(filas.enumerated()), id: \.offset) { i, f in
                    GridRow { ForEach(Array(f.enumerated()), id: \.offset) { _, c in TextoMD(texto: c, z: z, tam: 14, peso: i == 0 ? .semibold : .regular) } }
                    if i == 0 { Divider().gridCellUnsizedAxes(.horizontal) }
                }
            }
            .padding(12 * z).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10 * z))
        case .detalles(let r, let hijos, let l):
            // las respuestas se abren solo cuando ya grabó todas las preguntas de antes en este paso
            let antes = s.clase?.pasos.first { $0.id == pasoId }?.respuestas.filter { $0.linea < l }.map(\.nombre) ?? []
            ConCandado(nombres: antes, fecha: s.estado.fecha, g: s.grabador, z: z) {
                Desplegable(resumen: r, z: z) { VistaBloques(bloques: hijos, pasoId: pasoId, s: s, z: z) }
            }
        case .regla:
            Divider().opacity(0.4).padding(.vertical, 10 * z)
        }
    }
}

/// Esconde el contenido (las respuestas) hasta que estén todas esas grabaciones, y ninguna se esté grabando.
struct ConCandado<Contenido: View>: View {
    let nombres: [String]
    let fecha: String
    @ObservedObject var g: Grabador
    let z: CGFloat
    @ViewBuilder let contenido: () -> Contenido

    var body: some View {
        let faltan = nombres.filter { !g.existe($0, fecha: fecha) || g.grabando == $0 }.count
        if faltan == 0 {
            contenido()
        } else {
            HStack(spacing: 10 * z) {
                Image(systemName: "lock.fill").font(.system(size: 12 * z, weight: .semibold)).foregroundStyle(.secondary)
                Text(faltan == 1 ? "Graba la respuesta que falta para ver las respuestas"
                                 : "Graba las \(faltan) respuestas que faltan para ver las respuestas")
                    .font(.system(size: 15 * z, weight: .semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(12 * z)
        }
    }
}

/// Un <details>: toda la cabecera (no solo la flecha) lo abre y lo cierra.
struct Desplegable<Contenido: View>: View {
    let resumen: String
    let z: CGFloat
    @ViewBuilder let contenido: () -> Contenido
    final class Estado: ObservableObject { @Published var abierto = false }
    @StateObject private var e = Estado()
    private var abierto: Bool { e.abierto }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeOut(duration: 0.15)) { e.abierto.toggle() } } label: {
                HStack(spacing: 10 * z) {
                    Image(systemName: "chevron.right").font(.system(size: 12 * z, weight: .semibold))
                        .rotationEffect(.degrees(abierto ? 90 : 0)).foregroundStyle(.secondary)
                    Text((try? AttributedString(markdown: traducir(resumen))) ?? AttributedString(traducir(resumen)))
                        .font(.system(size: 15 * z, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .padding(12 * z).contentShape(Rectangle())
            }
            .buttonStyle(.hover)
            if abierto { contenido().padding([.horizontal, .bottom], 12 * z).padding(.top, 4 * z) }
        }
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10 * z))
    }
}

struct CampoTexto: View {
    let valor: Binding<String>
    let z: CGFloat
    var body: some View {
        TextField("Escribe aquí…", text: valor, axis: .vertical)
            .textFieldStyle(.plain).font(.system(size: 15 * z))
            .padding(.horizontal, 12 * z).padding(.vertical, 8 * z)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10 * z))
    }
}

struct PreguntaSorpresa: View {
    @ObservedObject var s: Sesion
    let z: CGFloat
    var body: some View {
        VStack(alignment: .leading, spacing: 8 * z) {
            Button { s.pedirPreguntaSorpresa() } label: {
                Label(s.preguntaSorpresa == nil ? "Dame una pregunta sorpresa" : "Otra pregunta", systemImage: "die.face.5")
                    .font(.system(size: 14 * z, weight: .semibold)).padding(.horizontal, 14 * z).padding(.vertical, 8 * z)
            }.buttonStyle(.glass)
            if let q = s.preguntaSorpresa {
                Text(q).font(.system(size: 18 * z, weight: .semibold, design: .rounded)).padding(14 * z)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12 * z))
            }
        }
    }
}

struct FilaGrabacion: View {
    let nombre: String
    @ObservedObject var s: Sesion
    @ObservedObject var g: Grabador
    let z: CGFloat
    var titulo: String? = nil

    var body: some View {
        let fecha = s.estado.fecha
        let grabandoEste = g.grabando == nombre
        let hay = g.existe(nombre, fecha: fecha)
        let borrada = g.borrada(nombre, fecha: fecha)
        // reproducir a la izquierda y grabar o regrabar a la derecha (antes al revés)
        HStack(spacing: 12 * z) {
            if hay && !borrada && !grabandoEste {
                Button { g.escuchar(nombre, fecha: fecha) } label: {
                    Image(systemName: g.sonando == nombre ? "pause.fill" : "play.fill").font(.system(size: 13 * z)).frame(width: 30 * z, height: 30 * z)
                }.buttonStyle(.glass).buttonBorderShape(.circle).help("Escuchar")
            }
            VStack(alignment: .leading, spacing: 2 * z) {
                if let titulo { Text(traducir(titulo)).font(.system(size: 14 * z, weight: .semibold)) }
                Text("\(fecha)_\(nombre).wav").font(.system(size: (titulo == nil ? 13 : 11) * z, weight: titulo == nil ? .semibold : .regular, design: .monospaced))
                    .foregroundStyle(titulo == nil ? Color.primary : Color.secondary)
                if grabandoEste {
                    HStack(spacing: 8 * z) {
                        Text(String(format: "%d:%02d", Int(g.segundos) / 60, Int(g.segundos) % 60)).monospacedDigit()
                        Capsule().fill(Color.white.opacity(0.12)).frame(width: 120 * z, height: 5 * z)
                            .overlay(alignment: .leading) { Capsule().fill(g.nivel > 0.9 ? Color.desafinado : Color.afinado).frame(width: 120 * z * CGFloat(min(1, g.nivel)), height: 5 * z) }
                    }.font(.system(size: 12 * z)).foregroundStyle(Color.red)
                } else if borrada, let d = g.duracion(nombre, fecha: fecha) {
                    Text(String(format: traducir("Grabada · %d:%02d · el audio se borró al evaluar la clase"), Int(d) / 60, Int(d) % 60))
                        .font(.system(size: 12 * z)).foregroundStyle(.secondary)
                } else if hay, let d = g.duracion(nombre, fecha: fecha) {
                    Text(String(format: traducir("Grabada · %d:%02d"), Int(d) / 60, Int(d) % 60)).font(.system(size: 12 * z)).foregroundStyle(Color.afinado)
                    barraDeTiempo(d, fecha: fecha)
                } else {
                    Text("Sin grabar").font(.system(size: 12 * z)).foregroundStyle(.secondary)
                }
            }
            Button {
                if grabandoEste { g.detener() }
                else if hay { s.pedirRegrabar(nombre) }
                else { s.marcarQueGrabo(); g.grabar(nombre, fecha: fecha) }
            } label: {
                Image(systemName: grabandoEste ? "stop.fill" : "record.circle")
                    .font(.system(size: 16 * z, weight: .bold)).foregroundStyle(grabandoEste ? Color.white : Color.red)
                    .frame(width: 34 * z, height: 34 * z)
            }
            .buttonStyle(.glass).buttonBorderShape(.circle)
            .help(grabandoEste ? "Parar" : (hay ? "Volver a grabar (te pide confirmar: la anterior va a la Papelera)" : "Grabar"))
        }
        .padding(.vertical, 6 * z).padding(.horizontal, 10 * z)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12 * z))
    }

    /// Se arrastra o se hace clic para adelantar o volver atrás.
    private func barraDeTiempo(_ d: Double, fecha: String) -> some View {
        let actual = g.cargado == nombre ? g.posicion : 0
        let valor = Binding<Double>(get: { actual }, set: { g.mover(nombre, fecha: fecha, a: $0) })
        return HStack(spacing: 8 * z) {
            Text(String(format: "%d:%02d", Int(actual) / 60, Int(actual) % 60)).monospacedDigit()
            Slider(value: valor, in: 0...max(d, 0.1)) { g.arrastrando = $0 }
                .controlSize(.small).frame(minWidth: 200 * z)
            Text(String(format: "%d:%02d", Int(d) / 60, Int(d) % 60)).monospacedDigit()
        }
        .font(.system(size: 11 * z)).foregroundStyle(.secondary)
    }
}

// MARK: Pantalla de inicio

struct VistaInicio: View {
    @ObservedObject var s: Sesion
    @ObservedObject var p: Practica
    var z: CGFloat { p.escala / 1.35 * 1.45 }

    var body: some View {
        VStack(spacing: 22 * z) {
            Button { s.pantalla = .materia(Carpeta.raiz) } label: {
                Label(s.nombreMateria, systemImage: "chevron.left").font(.system(size: 13 * z, weight: .semibold))
            }.buttonStyle(.enlace(z)).foregroundStyle(.secondary)
            Text(s.nombreMateria).font(.system(size: 40 * z, weight: .bold, design: .rounded))
            Text(fechaLarga()).font(.system(size: 15 * z)).foregroundStyle(.secondary)
            Group {
                if let aviso = s.aviso {
                    Text(aviso).font(.system(size: 15 * z))
                } else if let c = s.clase {
                    VStack(alignment: .leading, spacing: 12 * z) {
                        Text("CLASE PENDIENTE").font(.system(size: 11 * z, weight: .semibold)).kerning(1.2).foregroundStyle(.secondary)
                        TextoMD(texto: c.titulo, z: z, tam: 22, peso: .bold)
                        let objetivo = c.intro.first { $0.contains("Objetivo") }
                        if let o = objetivo { TextoMD(texto: o.replacingOccurrences(of: "> ", with: ""), z: z, tam: 14).foregroundStyle(Color.suave) }
                        HStack(spacing: 10 * z) {
                            if Carpeta.conCalentamiento { etiqueta(s.estado.calentado ? "Calentamiento hecho" : "Falta calentar", s.estado.calentado) }
                            etiqueta(L("Paso \(s.estado.paso + 1) de \(c.pasos.count)"), s.estado.paso > 0)
                            if !s.grabacionesPedidas.isEmpty {
                                let hechas = s.grabacionesPedidas.filter { s.grabador.existe($0, fecha: s.estado.fecha) }.count
                                etiqueta(L("\(hechas)/\(s.grabacionesPedidas.count) grabaciones"), hechas == s.grabacionesPedidas.count)
                            }
                        }
                        HStack(spacing: 12 * z) {
                            Button { s.empezar() } label: {
                                Text(s.estado.paso > 0 || s.estado.calentado ? "Continuar la clase" : Carpeta.conCalentamiento ? "Empezar: calentamiento" : "Empezar la clase")
                                    .font(.system(size: 15 * z, weight: .semibold)).padding(.horizontal, 18 * z).padding(.vertical, 10 * z)
                            }.buttonStyle(.glassProminent)
                            if !s.estado.calentado, Carpeta.conCalentamiento {
                                Button("Saltar calentamiento") { s.terminarCalentamiento() }.buttonStyle(.enlace(z)).foregroundStyle(.secondary)
                                    .font(.system(size: 13 * z))
                            }
                        }.padding(.top, 6 * z)
                    }
                    .frame(maxWidth: 640 * z, alignment: .leading)
                } else if case .crear(let n, _) = s.pendiente, !Carpeta.conCalentamiento {
                    VStack(alignment: .leading, spacing: 12 * z) {
                        Text("CLASE \(n)").font(.system(size: 11 * z, weight: .semibold)).kerning(1.2).foregroundStyle(.secondary)
                        Text(s.trabajando != nil ? "Claude está preparando la clase…" : "La clase de hoy todavía no está lista.")
                            .font(.system(size: 20 * z, weight: .bold))
                        Text("Sale del plan de la materia y de lo que ya aprendiste. Todo se responde grabando.")
                            .font(.system(size: 14 * z)).foregroundStyle(Color.suave)
                        if s.trabajando == nil {
                            Button { s.crearClase() } label: {
                                Label("Preparar la clase", systemImage: "sparkles").font(.system(size: 15 * z, weight: .semibold))
                                    .padding(.horizontal, 18 * z).padding(.vertical, 10 * z)
                            }.buttonStyle(.glassProminent)
                        }
                        Registro(s: s, z: z)
                    }
                    .frame(maxWidth: 640 * z, alignment: .leading)
                } else if case .crear(let n, _) = s.pendiente {
                    VStack(alignment: .leading, spacing: 12 * z) {
                        Text("CLASE \(n)").font(.system(size: 11 * z, weight: .semibold)).kerning(1.2).foregroundStyle(.secondary)
                        Text("Primero, a calentar la voz.").font(.system(size: 20 * z, weight: .bold))
                        Text("Mientras calientas, Claude prepara la clase siguiendo tu plan y tus estudios. Al terminar el calentamiento ya estará lista.")
                            .font(.system(size: 14 * z)).foregroundStyle(Color.suave)
                        Button { s.calentarYCrear() } label: {
                            Label("Empezar: calentamiento", systemImage: "music.note").font(.system(size: 15 * z, weight: .semibold))
                                .padding(.horizontal, 18 * z).padding(.vertical, 10 * z)
                        }.buttonStyle(.glassProminent).disabled(s.trabajando != nil)
                        Registro(s: s, z: z)
                    }
                    .frame(maxWidth: 640 * z, alignment: .leading)
                }
            }
            .tarjeta(z, ancha: false)
            if Carpeta.conCalentamiento {
            Button {
                // si la clase de hoy no existe, también se pide mientras calientas
                if case .crear = s.pendiente, s.trabajando == nil { s.calentarYCrear() } else { s.pantalla = .calentar }
            } label: {
                Label("Solo calentar", systemImage: "music.note").font(.system(size: 13 * z))
            }.buttonStyle(.enlace(z)).foregroundStyle(.secondary)
            }
        }
        .padding(30 * z)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func etiqueta(_ t: String, _ ok: Bool) -> some View {
        Label(traducir(t), systemImage: ok ? "checkmark.circle.fill" : "circle").font(.system(size: 12 * z, weight: .medium))
            .foregroundStyle(ok ? Color.afinado : Color.suave)
            .padding(.horizontal, 10 * z).padding(.vertical, 5 * z).background(Color.white.opacity(0.06), in: Capsule())
    }

    private func fechaLarga() -> String {
        let f = DateFormatter()
        if appEnIngles { f.locale = Locale(identifier: "en_US"); f.setLocalizedDateFormatFromTemplate("EEEEMMMMd") }
        else { f.locale = Locale(identifier: "es_CO"); f.dateFormat = "EEEE d 'de' MMMM" }
        let t = f.string(from: Date())
        return t.prefix(1).uppercased() + t.dropFirst()
    }
}

/// Lo que van diciendo las herramientas mientras trabajan.
struct Registro: View {
    @ObservedObject var s: Sesion
    let z: CGFloat
    var body: some View {
        if s.trabajando != nil || !s.registro.isEmpty {
            VStack(alignment: .leading, spacing: 8 * z) {
                // a la vista solo qué se está haciendo; el detalle va escondido
                if let t = s.trabajando {
                    HStack(spacing: 8 * z) { ProgressView().controlSize(.small); Text(t).font(.system(size: 13 * z, weight: .semibold)) }
                    if let ultimo = s.registro.last(where: { $0.hasPrefix("1/3") || $0.hasPrefix("2/3") || $0.hasPrefix("3/3") }) {
                        Text(ultimo).font(.system(size: 12 * z)).foregroundStyle(.secondary)
                    }
                }
                Desplegable(resumen: "Ver el detalle", z: z) { detalle }
            }
        }
    }

    private var detalle: some View {
                ScrollViewReader { sv in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2 * z) {
                            ForEach(Array(s.registro.suffix(200).enumerated()), id: \.offset) { i, l in
                                Text(l).font(.system(size: 11 * z, design: .monospaced)).foregroundStyle(.secondary).id(i)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160 * z)
                    .onChange(of: s.registro.count) { _, _ in sv.scrollTo(min(199, s.registro.count - 1), anchor: .bottom) }
                }
    }
}

// MARK: Pantalla de la clase

struct VistaClase: View {
    @ObservedObject var s: Sesion
    @ObservedObject var p: Practica
    var z: CGFloat { p.escala / 1.35 * 1.2 }
    /// El menú no se encoge más que la burbuja de los tres iconos, y esa burbuja mide lo mismo de alto que la barra.
    var anchoMinimo: CGFloat { 230 * z }
    var altoBarra: CGFloat { 48 * z }
    /// La lección (el centro) va más grande que el resto.
    var zl: CGFloat { z * 1.3 }

    var body: some View {
        if let c = s.clase {
            let paso = c.pasos[s.estado.paso]
            VStack(spacing: 12 * z) {
                HStack(alignment: .top, spacing: 0) {
                    if s.menuVisible {
                        menu(c).frame(width: max(anchoMinimo, s.anchoMenu)).padding(.top, 34 * z)
                        tirador
                    }
                    // el paso, centrado en el espacio que queda
                    ScrollView {
                        VStack(alignment: .leading, spacing: 26 * zl) {
                            TextoMD(texto: paso.titulo, z: zl, tam: 24, peso: .bold)
                            VistaBloques(bloques: Bloque.leer(paso.lineas), pasoId: paso.id, s: s, z: zl)
                        }
                        .frame(maxWidth: 860 * zl, alignment: .leading)
                        .padding(.horizontal, 24 * z).padding(.top, 46 * z).padding(.bottom, 40 * z)
                        .frame(maxWidth: .infinity)
                    }
                    // el texto se desvanece arriba y abajo en vez de cortarse
                    .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.06),
                                                 .init(color: .black, location: 0.92), .init(color: .clear, location: 1)],
                                         startPoint: .top, endPoint: .bottom))
                    .ignoresSafeArea(.container, edges: .top)
                    // llegar al final de la página marca el paso como leído
                    .onScrollGeometryChange(for: Bool.self) { g in
                        g.contentOffset.y + g.containerSize.height >= g.contentSize.height - 24
                    } action: { _, alFinal in
                        if alFinal { s.marcarVisto(paso.id) }
                    }
                    .id(paso.id)
                }
                if let e = s.grabador.error { Text(e).foregroundStyle(Color.desafinado).font(.system(size: 13 * z)) }
                // fila de abajo: igual con el menú abierto o cerrado, así la burbuja no se mueve
                HStack(spacing: 12 * z) {
                    iconosMenu
                        .padding(.horizontal, 18 * z)
                        .frame(width: anchoMinimo, height: altoBarra)
                        .glassEffect(.clear, in: Capsule())
                    barra(c)
                }
            }
            .padding(.horizontal, 20 * z).padding(.bottom, 18 * z)
        }
    }

    private func menu(_ c: Clase) -> some View {
        VStack(alignment: .leading, spacing: 4 * z) {
            TextoMD(texto: c.titulo, z: z, tam: 15, peso: .bold).padding(.bottom, 8 * z)
            ScrollView {
                VStack(alignment: .leading, spacing: 2 * z) {
                    ForEach(c.pasos) { pa in
                        Button { s.ir(aPaso: pa.id) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8 * z) {
                                icono(pa)
                                Text(pa.titulo.replacingOccurrences(of: "**", with: "")).multilineTextAlignment(.leading)
                            }
                            .font(.system(size: 14 * z, weight: pa.id == s.estado.paso ? .semibold : .regular))
                            .padding(.horizontal, 10 * z).padding(.vertical, 8 * z)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(pa.id == s.estado.paso ? Color.white.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10 * z))
                            .contentShape(Rectangle())
                        }.buttonStyle(.hover)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .tarjeta(z)
    }

    /// Inicio a la izquierda, calentamiento en el centro y abrir/cerrar el menú a la derecha.
    private var iconosMenu: some View {
        HStack {
            Button { s.grabador.detener(); s.pantalla = .inicio } label: { Image(systemName: "house") }
                .help("Volver al inicio")
            Spacer()
            Button { s.grabador.detener(); s.pantalla = .calentar } label: { Image(systemName: "music.note") }
                .help("Ir al calentamiento")
            Spacer()
            Button { s.menuVisible.toggle() } label: { Image(systemName: "sidebar.left") }
                .help(s.menuVisible ? "Esconder el menú (⌘⇧M)" : "Mostrar el menú (⌘⇧M)")
        }
        .buttonStyle(.icono(36 * z))
        .font(.system(size: 17 * z))
        .foregroundStyle(Color.suave)
    }

    /// Verde: leído hasta el final y con todo grabado. Micrófono naranja: leído pero falta grabar.
    @ViewBuilder private func icono(_ pa: Paso) -> some View {
        let grabs = pa.grabaciones
        let faltan = grabs.filter { !s.grabador.existe($0, fecha: s.estado.fecha) }.count
        if s.vio(pa.id) && faltan == 0 {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.afinado)
        } else if s.vio(pa.id) {
            Image(systemName: "mic.circle.fill").foregroundStyle(Color.desafinado).help("Faltan \(faltan) grabaciones")
        } else {
            Image(systemName: grabs.isEmpty ? "circle" : "mic.circle").foregroundStyle(Color.suave.opacity(0.6))
        }
    }

    /// Se arrastra para cambiar el ancho del menú.
    private var tirador: some View {
        TiradorMenu(ancho: { max(anchoMinimo, s.anchoMenu) }, cambiar: { s.anchoMenu = min(900, max(anchoMinimo, $0.rounded())) })
            .frame(width: 14)
    }

    private func barra(_ c: Clase) -> some View {
        let f = Font.system(size: 15 * z, weight: .medium)
        return HStack(spacing: 12 * z) {
            if s.estado.paso > 0 {
                Button { s.ir(aPaso: s.estado.paso - 1) } label: { Label("Anterior", systemImage: "chevron.left").font(f).padding(.horizontal, 14 * z).padding(.vertical, 4 * z) }
            }
            Spacer()
            if s.estado.paso < c.pasos.count - 1 {
                Button { s.ir(aPaso: s.estado.paso + 1) } label: { Label("Siguiente", systemImage: "chevron.right").font(f).padding(.horizontal, 14 * z).padding(.vertical, 4 * z) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command])
            }
            if s.claseCompleta {
                Button { s.grabador.detener(); s.pantalla = .evaluar } label: { Label("Terminar y evaluar", systemImage: "checkmark.seal").font(f).padding(.horizontal, 14 * z).padding(.vertical, 4 * z) }
                    .buttonStyle(.glassProminent)
            }
        }
        .buttonStyle(.glass)
        .font(.system(size: 15 * z, weight: .medium))
        .padding(.horizontal, 14 * z)
        .frame(height: altoBarra)
        .glassEffect(.clear, in: Capsule())
    }
}

/// Tirador nativo: sigue la posición real del ratón en la pantalla, así el menú no tiembla al cambiar de ancho.
struct TiradorMenu: NSViewRepresentable {
    let ancho: () -> CGFloat
    let cambiar: (CGFloat) -> Void

    final class Vista: NSView {
        var ancho: () -> CGFloat = { 0 }
        var cambiar: (CGFloat) -> Void = { _ in }
        private var inicioX: CGFloat = 0, anchoInicial: CGFloat = 0
        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
        override func mouseDown(with e: NSEvent) { inicioX = NSEvent.mouseLocation.x; anchoInicial = ancho() }
        override func mouseDragged(with e: NSEvent) {
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { cambiar(anchoInicial + NSEvent.mouseLocation.x - inicioX) }
        }
    }
    func makeNSView(context: Context) -> Vista { let v = Vista(); updateNSView(v, context: context); return v }
    func updateNSView(_ v: Vista, context: Context) { v.ancho = ancho; v.cambiar = cambiar }
}

/// Para elegir el estilo del botón según el caso.
struct AnyPrimitiveButtonStyle: PrimitiveButtonStyle {
    private let hacer: (Configuration) -> AnyView
    init<S: PrimitiveButtonStyle>(_ s: S) { hacer = { conf in AnyView(Button(role: conf.role, action: conf.trigger) { conf.label }.buttonStyle(s)) } }
    func makeBody(configuration: Configuration) -> some View { hacer(configuration) }
}

// MARK: Pantalla de evaluación

struct VistaEvaluar: View {
    @ObservedObject var s: Sesion
    @ObservedObject var p: Practica
    var z: CGFloat { p.escala / 1.35 * 1.2 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18 * z) {
                HStack {
                    Button { s.pantalla = .clase } label: {
                        Label("Volver a la clase", systemImage: "chevron.left").padding(.horizontal, 12 * z).padding(.vertical, 7 * z).contentShape(Rectangle())
                    }.buttonStyle(.hover)
                    Spacer()
                    Button { s.pantalla = .inicio } label: {
                        Label("Inicio", systemImage: "house").padding(.horizontal, 12 * z).padding(.vertical, 7 * z).contentShape(Rectangle())
                    }.buttonStyle(.hover)
                }.font(.system(size: 13 * z, weight: .semibold))
                Text("Cerrar la clase \(s.clase?.numero ?? 0)").font(.system(size: 28 * z, weight: .bold, design: .rounded))

                // lo que más importa: el veredicto, arriba y grande
                if let ev = s.estado.evaluacion {
                    VStack(alignment: .leading, spacing: 14 * z) {
                        Label("Veredicto", systemImage: "sparkles").font(.system(size: 20 * z, weight: .bold, design: .rounded))
                        VistaBloques(bloques: Bloque.leer(ev.components(separatedBy: "\n")), pasoId: -1, s: s, z: z * 1.1)
                        HStack {
                            Spacer()
                            Button { s.recargar(); s.pantalla = .inicio } label: {
                                Label("Listo, volver al inicio", systemImage: "house").padding(.horizontal, 14 * z).padding(.vertical, 8 * z)
                            }.buttonStyle(.glass)
                        }
                    }.tarjeta(z)
                }


                VStack(alignment: .leading, spacing: 8 * z) {
                    Text("TU AUTOEVALUACIÓN").font(.system(size: 11 * z, weight: .semibold)).kerning(1.2).foregroundStyle(.secondary)
                    Text(L("Antes de que Claude opine, dilo en voz alta: ¿qué crees que salió bien y qué salió mal?") + (Carpeta.esOratoria ? " " + L("Si contaste tus muletillas, dilo también.") : ""))
                        .font(.system(size: 14 * z)).foregroundStyle(Color.suave)
                    FilaGrabacion(nombre: "autoevaluacion", s: s, g: s.grabador, z: z, titulo: "Tu autoevaluación")
                }.tarjeta(z)

                // el botón va solo, a la derecha, debajo de la tarjeta
                HStack {
                    Spacer()
                    Button { s.evaluar() } label: {
                        Label(s.estado.evaluada ? "Evaluar de nuevo" : "Evaluar la clase", systemImage: "sparkles")
                            .font(.system(size: 15 * z, weight: .semibold)).padding(.horizontal, 18 * z).padding(.vertical, 10 * z)
                    }.buttonStyle(.glassProminent).disabled(s.trabajando != nil)
                }
                Registro(s: s, z: z)

            }
            .frame(maxWidth: 820 * z, alignment: .leading)
            .padding(.horizontal, 24 * z).padding(.top, 40 * z).padding(.bottom, 24 * z)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - La ventana

struct Raiz: View {
    @ObservedObject var s: Sesion
    @ObservedObject var p: Practica
    @ObservedObject var m: Materias

    /// Inicio (solo la casa) y Clase, del mismo tamaño que el selector de rutina.
    private var botonesCalentamiento: some View {
        let e = p.escala
        return HStack(spacing: 10 * e) {
            Button { p.pausar(); p.apagarMic(); s.pantalla = s.soloAfinador ? .materias : .inicio; s.soloAfinador = false } label: {
                Image(systemName: "house").frame(width: 36 * e, height: 36 * e).contentShape(Circle())
            }
            .buttonStyle(.hoverCapsula).glassEffect(.regular, in: Circle()).help("Inicio")
            if s.clase != nil, !s.soloAfinador {
                Button { p.pausar(); p.apagarMic(); s.terminarCalentamiento() } label: {
                    Label("Clase", systemImage: "arrow.right").padding(.horizontal, 16 * e).frame(height: 36 * e).contentShape(Capsule())
                }
                .buttonStyle(.hoverCapsula).glassEffect(.regular.tint(.accentColor.opacity(0.6)), in: Capsule())
                .help("Ir a la clase")
            } else if s.trabajando != nil, !s.soloAfinador {
                // la clase se está escribiendo mientras calientas
                HStack(spacing: 8 * e) { ProgressView().controlSize(.small); Text("Preparando la clase…") }
                    .padding(.horizontal, 16 * e).frame(height: 36 * e).glassEffect(.regular, in: Capsule())
                    .foregroundStyle(.secondary).help("Claude está escribiendo la clase; el botón aparece cuando esté lista")
            }
        }
        .font(.system(size: 14 * e, weight: .semibold))
        .fixedSize()
    }

    var body: some View {
        ZStack {
            VidrioVentana().ignoresSafeArea()
            LinearGradient(colors: [Color.fondo2.opacity(0.72), Color.fondo.opacity(0.86)], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            // doble clic en la franja de arriba (donde estaría la barra de título): llenar la pantalla, como en las demás apps
            VStack(spacing: 0) { BarraDeTitulo().frame(height: 60); Spacer(minLength: 0) }.ignoresSafeArea()
            // la primera vez: quién eres y qué quieres lograr
            if Perfil.actual == nil {
                ScrollView { VistaPerfil(s: s, m: m, z: p.escala / 1.35 * 1.2, bienvenida: true) { s.pantalla = .materias }
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26)).padding(40) }
            } else {
            switch s.pantalla {
            case .materias: VistaMaterias(s: s, p: p, m: m)
            case .materia(let u): VistaMateria(s: s, p: p, m: m, url: u)
            case .inicio: VistaInicio(s: s, p: p)
            case .calentar:
                Contenido(p: p, derecha: AnyView(botonesCalentamiento))
            case .clase: VistaClase(s: s, p: p)
            case .evaluar: VistaEvaluar(s: s, p: p)
            }
            }
        }
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .alert("¿Volver a grabar?", isPresented: Binding(get: { s.porRegrabar != nil }, set: { if !$0 { s.porRegrabar = nil } })) {
            Button("Cancelar", role: .cancel) { s.porRegrabar = nil }
            Button("Regrabar", role: .destructive) { s.confirmarRegrabar() }
        } message: {
            Text("Vas a perder la grabación que ya hiciste: \(s.estado.fecha)_\(s.candidatoARegrabar ?? "").wav va a la Papelera y empieza una nueva.")
        }
        .frame(minWidth: 980, minHeight: 560)
        .preferredColorScheme(.dark)
    }
}

@main
struct OratoriaApp: App {
    @StateObject private var p = Practica()
    @StateObject private var s = Sesion()
    @StateObject private var m = Materias()

    var body: some Scene {
        WindowGroup("Estudio") { Raiz(s: s, p: p, m: m) }
            .windowStyle(.hiddenTitleBar)
            .defaultSize(width: 1600, height: 900)
            .commands {
                CommandGroup(after: .toolbar) {
                    Button("Agrandar") { p.zoom(0.1) }.keyboardShortcut("=")
                    Button("Achicar") { p.zoom(-0.1) }.keyboardShortcut("-")
                    Button("Tamaño normal") { p.escala = 1.35 }.keyboardShortcut("0")
                    Divider()
                    Button("Restablecer zoom del piano roll") { p.zoomRoll = 1 }.keyboardShortcut("0", modifiers: [.command, .option])
                    Divider()
                    Button("Mostrar u ocultar el menú de la clase") { s.menuVisible.toggle() }.keyboardShortcut("m", modifiers: [.command, .shift])
                }
                CommandMenu("Grabación") { MenuGanancia(g: s.grabador) }
                CommandGroup(after: .appSettings) { MenuIdioma() }
            }
    }
}

/// Menú Grabación → Volumen: cuánto se sube la voz al grabar (se usa desde la siguiente grabación).
struct MenuGanancia: View {
    @ObservedObject var g: Grabador
    var body: some View {
        Picker("Subir el volumen al grabar", selection: $g.ganancia) {
            ForEach(Grabador.ganancias, id: \.self) { d in
                Text(d == 0 ? L("Sin subir (0 dB)") : "+\(Int(d)) dB" + (d == 12 ? " " + L("(recomendado)") : "")).tag(d)
            }
        }
        .pickerStyle(.inline)
    }
}


// MARK: - Idioma de la app

/// En el menú de la app (junto a Ajustes de macOS): español o inglés. Cambia los textos de la app y los menús de macOS
/// (la app guarda su propio AppleLanguages); se aplica al volver a abrirla. El idioma de las clases va en el perfil.
struct MenuIdioma: View {
    private var actual: String {
        (UserDefaults.standard.array(forKey: "AppleLanguages") as? [String])?.first.map { $0.hasPrefix("en") ? "en" : "es" } ?? "es"
    }

    var body: some View {
        Menu("Idioma de la app") {
            ForEach([("es", "Español"), ("en", "English")], id: \.0) { codigo, nombre in
                Button { cambiar(a: codigo) } label: {
                    if codigo == actual { Label(nombre, systemImage: "checkmark") } else { Text(nombre) }
                }
            }
        }
    }

    private func cambiar(a codigo: String) {
        guard codigo != actual else { return }
        UserDefaults.standard.set([codigo], forKey: "AppleLanguages")
        let a = NSAlert()
        a.messageText = codigo == "en" ? "Restart Estudio to change the language" : "Reinicia Estudio para cambiar el idioma"
        a.informativeText = codigo == "en" ? "The menus and texts of the app will be in English." : "Los menús y los textos de la app quedarán en español."
        a.addButton(withTitle: codigo == "en" ? "Restart now" : "Reiniciar ahora")
        a.addButton(withTitle: codigo == "en" ? "Later" : "Después")
        if a.runModal() == .alertFirstButtonReturn {
            let ruta = Bundle.main.bundlePath
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "sleep 1; /usr/bin/open \"\(ruta)\""]
            try? p.run()
            NSApp.terminate(nil)
        }
    }
}
