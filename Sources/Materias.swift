import SwiftUI
import AppKit

// MARK: - Materias

/// Lo que se ajusta de cada materia. Se guarda en <materia>/materia.json.
struct AjustesMateria: Codable, Equatable {
    /// Porcentaje de la clase que es teoría; el resto es práctica.
    var teoria: Double = 30
    /// Minutos de reloj que dura la clase.
    var duracion: Int = 45
    /// Tus reglas para enseñar esta materia (se suman a las de su CLAUDE.md).
    var comoEnsenar: String = ""
    /// El nombre que le pusiste en la app (Cambiar el nombre). La carpeta no se renombra: otras notas apuntan a ella.
    var nombre: String?
    /// Símbolo de SF Symbols de su card.
    var icono: String?
    /// Antes de cada clase va el calentamiento de voz con el afinador.
    var calentamiento: Bool?
    /// "oratoria": usa los pedidos propios de oratoria (ronda diaria, pregunta sorpresa, palabra del día…).
    var plantilla: String?
}

/// Una materia es una carpeta de ~/Study, con su CLAUDE.md, su plan (plan/PLAN.md) y sus clases (plan/clases/).
struct Materia: Identifiable, Equatable {
    let url: URL
    var id: URL { url }
    var ajustes: AjustesMateria
    var tienePlan: Bool
    var clases: Int

    var carpeta: String { url.lastPathComponent }
    var esOratoria: Bool { ajustes.plantilla == "oratoria" }

    /// El nombre para mostrar: el que le pusiste en la app; si no, los de siempre con tilde y en español, y las demás,
    /// como se llame su carpeta.
    var nombre: String {
        ajustes.nombre?.nonEmpty ?? carpeta.replacingOccurrences(of: "&", with: " y ")
    }

    var icono: String { ajustes.icono?.nonEmpty ?? "book" }

    var plan: URL { url.appendingPathComponent("plan/PLAN.md") }
    var instrucciones: URL { url.appendingPathComponent("CLAUDE.md") }
}

final class Materias: ObservableObject {
    /// La carpeta de las materias: la que eligió la persona en su perfil.
    static var raiz: URL { URL(fileURLWithPath: Perfil.actual?.carpeta ?? Perfil().carpeta, isDirectory: true) }

    /// Las carpetas de materias, por nombre.
    static func todas() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: raiz, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// La primera materia cuyos ajustes cumplen la condición.
    static func buscar(_ cumple: (AjustesMateria) -> Bool) -> URL? { todas().first { cumple(leerAjustes($0)) } }

    @Published private(set) var lista: [Materia] = []

    init() { cargar() }

    func cargar() {
        let fm = FileManager.default
        let carpetas = ((try? fm.contentsOfDirectory(at: Self.raiz, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        lista = carpetas.map { u in
            let clases = ((try? fm.contentsOfDirectory(atPath: u.appendingPathComponent("plan/clases").path)) ?? []).filter { $0.hasSuffix(".md") }.count
            return Materia(url: u, ajustes: Self.leerAjustes(u), tienePlan: fm.fileExists(atPath: u.appendingPathComponent("plan/PLAN.md").path), clases: clases)
        }
        // primero las que tienen clases, después por nombre
        .sorted { ($0.clases > 0) != ($1.clases > 0) ? $0.clases > 0 : $0.nombre.localizedStandardCompare($1.nombre) == .orderedAscending }
    }

    static func leerAjustes(_ u: URL) -> AjustesMateria {
        if let d = try? Data(contentsOf: u.appendingPathComponent("materia.json")), let a = try? JSONDecoder().decode(AjustesMateria.self, from: d) { return a }
        return AjustesMateria()
    }

    func guardar(_ a: AjustesMateria, en m: Materia) {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? e.encode(a).write(to: m.url.appendingPathComponent("materia.json"), options: .atomic)
        if let i = lista.firstIndex(where: { $0.url == m.url }) { lista[i].ajustes = a }
    }

    func materia(_ u: URL) -> Materia? { lista.first { $0.url == u } }

    /// Lo que la persona escribió en «Cómo se enseña», listo para ir en todo pedido a Claude de esa materia (crear y evaluar
    /// clases, armar y cambiar el plan). Vacío si no escribió nada.
    static func indicaciones(_ u: URL) -> String {
        let t = leerAjustes(u).comoEnsenar.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "" }
        return """
        ===== Lo que \(Perfil.trato) pide para esta materia =====
        Lo escribió él en la app («Cómo se enseña»). Son sus peticiones: cómo quiere que se armen y se evalúen las clases, \
        en qué enfocarse, su nivel, qué ya sabe y qué no. Tenlas en cuenta en todo lo que hagas aquí; si chocan con otra \
        regla de este pedido o de CLAUDE.md, mandan estas.
        \(t)
        ===== Fin de lo que pide \(Perfil.trato) =====

        """
    }
}

// MARK: - Pantalla de materias

struct VistaMaterias: View {
    @ObservedObject var s: Sesion
    @ObservedObject var p: Practica
    @ObservedObject var m: Materias
    @StateObject private var h = Hoja()
    @StateObject private var req = Requisitos()
    var z: CGFloat { p.escala / 1.35 * 1.45 }

    final class Hoja: ObservableObject { @Published var nueva = false; @Published var perfil = false }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22 * z) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Estudio").font(.system(size: 40 * z, weight: .bold, design: .rounded))
                    Spacer()
                    Button { h.perfil = true } label: {
                        Label(Perfil.actual?.nombre.nonEmpty ?? "Tu perfil", systemImage: "person.crop.circle").font(.system(size: 14 * z, weight: .semibold))
                    }.buttonStyle(.enlace(z)).foregroundStyle(.secondary).help("Tu perfil: quién eres, qué quieres lograr y el idioma de tus clases")
                }
                Text("¿Qué vas a estudiar hoy?").font(.system(size: 15 * z)).foregroundStyle(.secondary)

                if req.claude != .revisando, !req.listos { TarjetaRequisitos(r: req, z: z) }
                titulo("MATERIAS")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260 * z), spacing: 16 * z)], spacing: 16 * z) {
                    ForEach(m.lista) { materia in
                        Button { abrir(materia) } label: { card(materia) }.buttonStyle(.plain)
                    }
                    Button { h.nueva = true } label: {
                        VStack(spacing: 10 * z) {
                            Image(systemName: "plus").font(.system(size: 26 * z, weight: .semibold))
                            Text("Materia nueva").font(.system(size: 15 * z, weight: .semibold))
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 150 * z).contentShape(Rectangle())
                        .overlay(RoundedRectangle(cornerRadius: 20 * z).strokeBorder(Color.white.opacity(0.2), style: StrokeStyle(lineWidth: 1.5, dash: [6])))
                    }.buttonStyle(.plain)
                }
                if let aviso = s.aviso { Text(aviso).font(.system(size: 13 * z)).foregroundStyle(.orange) }

                titulo("HERRAMIENTAS")
                Button { s.abrirAfinador() } label: {
                    HStack(spacing: 14 * z) {
                        Image(systemName: "music.note").font(.system(size: 22 * z)).frame(width: 40 * z)
                        VStack(alignment: .leading, spacing: 3 * z) {
                            Text("Afinador").font(.system(size: 17 * z, weight: .semibold))
                            Text("Calentamiento de voz con el piano roll").font(.system(size: 12 * z)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(16 * z).frame(maxWidth: 360 * z, alignment: .leading).contentShape(Rectangle())
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18 * z))
                }.buttonStyle(.plain)
            }
            .padding(36 * z).frame(maxWidth: 1100 * z, alignment: .leading).frame(maxWidth: .infinity)
        }
        .onAppear { m.cargar() }
        .task { await req.revisar() }
        .sheet(isPresented: $h.perfil) { VistaPerfil(s: s, m: m, z: z, bienvenida: false) { h.perfil = false } }
        .sheet(isPresented: $h.nueva) { FormNuevaMateria(s: s, m: m, z: z) { h.nueva = false } }
    }

    private func titulo(_ t: String) -> some View {
        Text(t).font(.system(size: 11 * z, weight: .semibold)).kerning(1.2).foregroundStyle(.secondary).padding(.top, 8 * z)
    }

    private func card(_ materia: Materia) -> some View {
        VStack(alignment: .leading, spacing: 10 * z) {
            Image(systemName: materia.icono).font(.system(size: 26 * z)).foregroundStyle(Color.accentColor)
            Text(materia.nombre).font(.system(size: 19 * z, weight: .bold))
            Text(materia.clases > 0 ? "\(materia.clases) clase\(materia.clases == 1 ? "" : "s")" : materia.tienePlan ? "Plan listo, sin clases todavía" : "Sin plan todavía")
                .font(.system(size: 13 * z)).foregroundStyle(.secondary)
            Text("Teoría \(Int(materia.ajustes.teoria)) % · \(materia.ajustes.duracion) min")
                .font(.system(size: 12 * z)).foregroundStyle(.tertiary)
        }
        .padding(18 * z).frame(maxWidth: .infinity, minHeight: 150 * z, alignment: .topLeading).contentShape(Rectangle())
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20 * z))
    }

    /// Al tocar la card ya se empieza a preparar la clase de hoy (si toca una nueva) mientras miras el detalle.
    private func abrir(_ materia: Materia) {
        if s.usar(materia.url), materia.tienePlan, case .crear = s.pendiente, s.trabajando == nil { s.crearClase() }
        s.pantalla = .materia(materia.url)
    }
}

// MARK: - Detalle de una materia

struct VistaMateria: View {
    @ObservedObject var s: Sesion
    @ObservedObject var p: Practica
    @ObservedObject var m: Materias
    let url: URL
    @StateObject private var e = Edicion()
    var z: CGFloat { p.escala / 1.35 * 1.45 }

    final class Edicion: ObservableObject {
        @Published var ajustes = AjustesMateria()
        @Published var cargado: URL?
        @Published var borrar = false
        @Published var renombrar = false
        @Published var menu = false
        var espera: DispatchWorkItem?
    }

    /// Guarda medio segundo después de la última tecla (escribir en «cómo se enseña» no reescribe todo con cada letra).
    private func guardarLuego(_ a: AjustesMateria, _ materia: Materia) {
        e.espera?.cancel()
        let w = DispatchWorkItem { m.guardar(a, en: materia) }
        e.espera = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    var body: some View {
        if let materia = m.materia(url) {
            // La pantalla no se desplaza entera: llena la ventana, «Cómo se enseña» crece hasta abajo y solo el temario
            // tiene su propio scroll.
            VStack(alignment: .leading, spacing: 14 * z) {
                HStack(spacing: 12 * z) {
                    Button { s.pantalla = .materias } label: {
                        Label("Materias", systemImage: "chevron.left").font(.system(size: 13 * z, weight: .semibold))
                    }.buttonStyle(.enlace(z)).foregroundStyle(.secondary)
                    Spacer()
                }
                HStack(alignment: .center, spacing: 14 * z) {
                    Image(systemName: materia.icono).font(.system(size: 30 * z)).foregroundStyle(Color.accentColor)
                    Text(materia.nombre).font(.system(size: 36 * z, weight: .bold, design: .rounded))
                    menuMateria(materia)
                    Spacer()
                    botonIniciar(materia)
                }
                HStack(alignment: .top, spacing: 18 * z) {
                    VStack(alignment: .leading, spacing: 18 * z) {
                        tarjetaReparto
                        tarjetaDuracion
                        tarjetaComoEnsenar(materia)
                    }
                    .frame(width: 420 * z).frame(maxHeight: .infinity, alignment: .top)
                    tarjetaTemario(materia)
                }
                .frame(maxHeight: .infinity)
            }
            // arriba poco margen: la franja de la barra de título ya deja espacio para los botones de la ventana
            .padding(.horizontal, 36 * z).padding(.top, 6 * z).padding(.bottom, 28 * z)
            .frame(maxWidth: 1300 * z, maxHeight: .infinity, alignment: .topLeading).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onAppear { if e.cargado != url { e.ajustes = materia.ajustes; e.cargado = url } }
            .onChange(of: e.ajustes) { _, a in guardarLuego(a, materia) }
            .onDisappear { if e.espera != nil { e.espera?.cancel(); e.espera = nil; m.guardar(e.ajustes, en: materia) } }
            .sheet(isPresented: $e.borrar) {
                ConfirmarEliminar(nombre: materia.nombre, z: z, alCancelar: { e.borrar = false }) {
                    e.borrar = false
                    // si es la materia abierta, primero se abre otra (no se puede mientras Claude trabaja en ella)
                    if Carpeta.raiz.standardizedFileURL == materia.url.standardizedFileURL,
                       let otra = m.lista.first(where: { $0.url.standardizedFileURL != materia.url.standardizedFileURL }) {
                        guard s.usar(otra.url) else { return }
                    }
                    if m.eliminar(materia) { s.pantalla = .materias }
                }
            }
            .sheet(isPresented: $e.renombrar) {
                CambiarNombre(actual: materia.nombre, z: z, alCancelar: { e.renombrar = false }) { nuevo in
                    e.renombrar = false
                    e.ajustes.nombre = nuevo
                    m.guardar(e.ajustes, en: materia)   // al instante: el título cambia ya, sin esperar el guardado diferido
                }
            }
        } else {
            Text("Esta materia ya no está en ~/Study.").foregroundStyle(.secondary)
                .onAppear { s.pantalla = .materias }
        }
    }

    @ViewBuilder private func botonIniciar(_ materia: Materia) -> some View {
        if materia.tienePlan {
            Button { if s.usar(materia.url) { s.pantalla = .inicio } } label: {
                HStack(spacing: 8 * z) {
                    if s.trabajando != nil { ProgressView().controlSize(.small) }
                    Text(s.clase != nil ? "Ir a la clase" : s.trabajando != nil ? "Preparando la clase…" : "Iniciar nueva clase")
                }
                .font(.system(size: 15 * z, weight: .semibold)).padding(.horizontal, 18 * z).padding(.vertical, 10 * z)
            }.buttonStyle(.glassProminent)
        }
        // sin plan no hay nada aquí: el botón para armarlo está en el temario
    }

    /// Los tres puntos junto al nombre: abre un menú con el estilo de la app (cambiar el nombre, eliminar).
    private func menuMateria(_ materia: Materia) -> some View {
        Button { e.menu.toggle() } label: {
            Image(systemName: "ellipsis").font(.system(size: 16 * z, weight: .bold)).foregroundStyle(.secondary)
        }
        .buttonStyle(.icono(36 * z)).help("Más opciones")
        .popover(isPresented: $e.menu, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2 * z) {
                opcion("Cambiar el nombre", "pencil") { e.renombrar = true }
                Divider().padding(.vertical, 4 * z)
                opcion("Eliminar la materia", "trash", rojo: true) { e.borrar = true }
            }
            .padding(8 * z).frame(minWidth: 240 * z)
        }
    }

    private func opcion(_ t: String, _ icono: String, rojo: Bool = false, _ hacer: @escaping () -> Void) -> some View {
        Button {
            e.menu = false
            // la hoja se abre cuando el menú ya se cerró (si no, macOS no la muestra)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: hacer)
        } label: {
            Label(t, systemImage: icono).font(.system(size: 14 * z, weight: .medium))
                .foregroundStyle(rojo ? Color.red : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12 * z).padding(.vertical, 9 * z).contentShape(Rectangle())
        }
        .buttonStyle(.hover)
    }

    private func encabezado(_ t: String) -> some View {
        Text(t).font(.system(size: 11 * z, weight: .semibold)).kerning(1.2).foregroundStyle(.secondary)
    }

    /// La barra de teoría y práctica: el punto reparte el 100 % entre las dos.
    private var tarjetaReparto: some View {
        VStack(alignment: .leading, spacing: 10 * z) {
            encabezado("TEORÍA Y PRÁCTICA")
            HStack {
                Text("Teoría \(Int(e.ajustes.teoria)) %").font(.system(size: 15 * z, weight: .semibold))
                Spacer()
                Text("Práctica \(100 - Int(e.ajustes.teoria)) %").font(.system(size: 15 * z, weight: .semibold)).foregroundStyle(Color.accentColor)
            }
            Slider(value: $e.ajustes.teoria, in: 0...100, step: 5)
        }
        .padding(18 * z).frame(maxWidth: .infinity, alignment: .leading).glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20 * z))
    }

    private var tarjetaDuracion: some View {
        VStack(alignment: .leading, spacing: 10 * z) {
            encabezado("DURACIÓN DE LA CLASE")
            Stepper(value: $e.ajustes.duracion, in: 15...120, step: 5) {
                Text("\(e.ajustes.duracion) minutos de reloj").font(.system(size: 15 * z, weight: .semibold))
            }
            Text("La clase se arma para este tiempo, contando que leer, repetir o tomar agua también gastan tiempo.")
                .font(.system(size: 12 * z)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(18 * z).frame(maxWidth: .infinity, alignment: .leading).glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20 * z))
    }

    private func tarjetaComoEnsenar(_ materia: Materia) -> some View {
        VStack(alignment: .leading, spacing: 10 * z) {
            encabezado("CÓMO SE ENSEÑA")
            // alto fijo hasta el fondo de la ventana; si lo escrito es largo, se desplaza por dentro
            TextEditor(text: $e.ajustes.comoEnsenar)
                .font(.system(size: 14 * z)).scrollContentBackground(.hidden).scrollIndicators(.automatic)
                .frame(minHeight: 80 * z, maxHeight: .infinity).padding(8 * z)
                .background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 10 * z))
        }
        .padding(18 * z).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20 * z))
    }

    private func tarjetaTemario(_ materia: Materia) -> some View {
        TarjetaTemario(s: s, m: m, materia: materia, z: z)
    }
}

/// Campo de texto con el estilo de la app (el mismo de los campos de las clases).
struct CampoHoja: View {
    let titulo: String
    let texto: Binding<String>
    let z: CGFloat
    var body: some View {
        TextField(titulo, text: texto).textFieldStyle(.plain).font(.system(size: 15 * z))
            .padding(.horizontal, 12 * z).padding(.vertical, 9 * z)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10 * z))
            .overlay(RoundedRectangle(cornerRadius: 10 * z).strokeBorder(Color.white.opacity(0.12)))
    }
}

/// Los botones de abajo de las hojas, como los demás de la app (vidrio).
func botonHoja(_ t: String, _ z: CGFloat) -> some View {
    Text(t).font(.system(size: 14 * z, weight: .semibold)).padding(.horizontal, 14 * z).padding(.vertical, 6 * z)
}

/// Para eliminar una materia hay que escribir su nombre a mano, como en AWS: pegarlo no sirve.
struct ConfirmarEliminar: View {
    let nombre: String
    let z: CGFloat
    let alCancelar: () -> Void
    let alEliminar: () -> Void
    @StateObject private var f = Campo()
    final class Campo: ObservableObject { @Published var texto = "" }

    private var coincide: Bool { f.texto == nombre }

    var body: some View {
        VStack(alignment: .leading, spacing: 16 * z) {
            Label("Eliminar «\(nombre)»", systemImage: "trash").font(.system(size: 20 * z, weight: .bold)).foregroundStyle(.red)
            Text("Su carpeta, con el plan, las clases y las grabaciones, va a la Papelera: de ahí la puedes devolver.")
                .font(.system(size: 14 * z)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8 * z) {
                Text("Para confirmar, escribe el nombre de la materia:").font(.system(size: 14 * z, weight: .semibold))
                Text(nombre).font(.system(size: 15 * z, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 10 * z).padding(.vertical, 5 * z)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6 * z))
            }
            CampoHoja(titulo: "Escribe «\(nombre)»", texto: $f.texto, z: z)
                .onChange(of: f.texto) { viejo, nuevo in
                    // al escribir llega una letra a la vez; si llegan varias juntas es que se pegó: no vale
                    if nuevo.count > viejo.count + 1 { f.texto = viejo }
                }
                .onSubmit { if coincide { alEliminar() } }
            HStack(spacing: 10 * z) {
                Spacer()
                Button(action: alCancelar) { botonHoja("Cancelar", z) }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
                Button(role: .destructive, action: alEliminar) { botonHoja("Eliminar", z) }
                    .buttonStyle(.glassProminent).tint(.red).disabled(!coincide)
            }
        }
        .padding(28 * z).frame(width: 500 * z)
        .buttonBorderShape(.capsule).controlSize(.large)   // las hojas no heredan la forma de los botones de la ventana
    }
}

/// Cambiar el nombre con que se ve la materia en la app (la carpeta de ~/Study no se toca).
struct CambiarNombre: View {
    let actual: String
    let z: CGFloat
    let alCancelar: () -> Void
    let alGuardar: (String) -> Void
    @StateObject private var f = Campo()
    final class Campo: ObservableObject { @Published var texto = ""; var listo = false }

    private var limpio: String { f.texto.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var vale: Bool { !limpio.isEmpty && limpio != actual }

    var body: some View {
        VStack(alignment: .leading, spacing: 16 * z) {
            Text("Cambiar el nombre").font(.system(size: 20 * z, weight: .bold))
            CampoHoja(titulo: "Nombre de la materia", texto: $f.texto, z: z)
                .onSubmit { if vale { alGuardar(limpio) } }
            HStack(spacing: 10 * z) {
                Spacer()
                Button(action: alCancelar) { botonHoja("Cancelar", z) }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
                Button { alGuardar(limpio) } label: { botonHoja("Guardar", z) }.buttonStyle(.glassProminent).disabled(!vale)
            }
        }
        .padding(28 * z).frame(width: 460 * z)
        .buttonBorderShape(.capsule).controlSize(.large)   // las hojas no heredan la forma de los botones de la ventana
        .onAppear { if !f.listo { f.texto = actual; f.listo = true } }
    }
}
