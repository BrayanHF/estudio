import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

// MARK: - Crear, armar y editar el contenido de una materia

extension Materias {
    /// Crea la carpeta de la materia en ~/Study con su CLAUDE.md (qué quieres aprender y para qué) y tu material.
    /// Los PDF se guardan también como texto (material/texto/<nombre>.txt): Claude lee eso, nunca el PDF entero.
    func crear(nombre: String, descripcion: String, material: [URL], ajustes: AjustesMateria) -> URL? {
        let limpio = nombre.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        guard !limpio.isEmpty else { return nil }
        let fm = FileManager.default
        let u = Self.raiz.appendingPathComponent(limpio, isDirectory: true)
        guard !fm.fileExists(atPath: u.path) else { return nil }
        try? fm.createDirectory(at: u.appendingPathComponent("plan/clases"), withIntermediateDirectories: true)
        var lista: [String] = []
        if !material.isEmpty {
            let dir = u.appendingPathComponent("material"), textos = dir.appendingPathComponent("texto")
            try? fm.createDirectory(at: textos, withIntermediateDirectories: true)
            for m in material {
                let destino = dir.appendingPathComponent(m.lastPathComponent)
                try? fm.copyItem(at: m, to: destino)
                let base = m.deletingPathExtension().lastPathComponent
                if m.pathExtension.lowercased() == "pdf", let pdf = PDFDocument(url: m) {
                    var t = ""
                    for i in 0..<pdf.pageCount { t += "--- página \(i + 1) ---\n" + (pdf.page(at: i)?.string ?? "") + "\n" }
                    try? t.write(to: textos.appendingPathComponent(base + ".txt"), atomically: true, encoding: .utf8)
                } else if let t = try? String(contentsOf: m, encoding: .utf8) {
                    try? t.write(to: textos.appendingPathComponent(base + ".txt"), atomically: true, encoding: .utf8)
                }
                lista.append("- `material/\(m.lastPathComponent)` (texto en `material/texto/\(base).txt`)")
            }
        }
        let claude = """
        # \(limpio)

        > Materia de \(Perfil.trato) en su app Estudio. Aprende por su cuenta, con la IA como tutor, y en todas las materias practica \
        también la oratoria: todo lo responde hablando y grabando.

        ## Qué quiere aprender y para qué
        \(descripcion.trimmingCharacters(in: .whitespacesAndNewlines))

        ## Material propio
        \(lista.isEmpty ? "No agregó material: el plan sale de fuentes que investiga Claude." : lista.joined(separator: "\n"))
        """
        try? claude.write(to: u.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        guardar(ajustes, en: Materia(url: u, ajustes: ajustes, tienePlan: false, clases: 0))
        cargar()
        return u
    }

    /// Manda la materia a la Papelera (se puede devolver). Cualquiera, Oratoria también: las herramientas de voz son de la app.
    func eliminar(_ m: Materia) -> Bool {
        do { try FileManager.default.trashItem(at: m.url, resultingItemURL: nil) } catch { return false }
        cargar()
        return true
    }
}

extension Sesion {
    /// Claude investiga y arma el plan de la materia abierta, con la estructura del de Oratoria.
    func armarPlan() {
        guard trabajando == nil, !Carpeta.esOratoria else { return }
        let a = Materias.leerAjustes(Carpeta.raiz)
        let pedido = """
        Arma el plan de estudio de la materia «\(nombreMateria)», en esta carpeta.
        1. Lee CLAUDE.md: qué quiere aprender \(Perfil.trato) y para qué. Si hay material propio, está como texto en material/texto/: \
        búscalo con Grep y lee solo las partes que necesites (nunca un .txt largo entero ni un PDF).
        2. Investiga en internet fuentes confiables y verificables (oficiales, académicas, libros o cursos reconocidos) que \
        cubran lo que quiere aprender. Guarda lo esencial de cada una en estudios/texto/<nombre-corto>.txt, con su título y \
        su URL al inicio, y un estudios/README.md con la lista: fuente, URL, para qué sirve y qué tan confiable es \
        (✅ oficial o académica · ⚠️ divulgación o prensa). No inventes datos ni fuentes.
        3. Escribe plan/PLAN.md con esta estructura: un encabezado con qué se aprende, para qué, la base (las fuentes) y cómo es la clase; las metas por \
        bloque; y una sección "## Temario" con una tabla | Clase | Tema | Fuentes |, en orden de lo básico a lo avanzado. \
        Cada clase es un tema que cabe en una clase de \(a.duracion) minutos con \(Int(a.teoria)) % de teoría y el resto \
        de práctica hablada. Tantas clases como el tema necesite, sin relleno.
        4. Completa CLAUDE.md con una sección "## Cómo enseñar esta materia": enfoque, nivel de partida y qué evitar.
        \(Materias.indicaciones(Carpeta.raiz))\
        Responde solo con un resumen de 3 líneas: cuántas clases quedaron, de qué van y cuántas fuentes usaste.
        """
        trabajar("Claude está armando el plan de \(nombreMateria)…") {
            let r = await Herramientas.preguntarAClaude(pedido, web: true) { self.registro.append($0) }
            self.registro.append(r.ok ? r.respuesta : "Algo falló: \(r.respuesta)")
            self.recargar()
        }
    }

    /// Un cambio al temario pedido en palabras ("agrega un tema de X después de la clase 3", "quita la 7"…).
    func cambiarPlan(_ instruccion: String) {
        let t = instruccion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trabajando == nil, !t.isEmpty else { return }
        let pedido = """
        \(Perfil.trato) quiere este cambio en el plan de la materia «\(nombreMateria)» (plan/PLAN.md): \(t)
        Haz solo ese cambio en plan/PLAN.md y deja el resto como está. Si el temario está numerado, vuelve a numerar lo que \
        siga. No cambies las clases ya hechas (plan/clases/). Si necesitas una fuente nueva, busca en estudios/. Responde en \
        una línea qué cambiaste.
        \(Materias.indicaciones(Carpeta.raiz))
        """
        trabajar("Claude está cambiando el plan…") {
            let r = await Herramientas.preguntarAClaude(pedido) { self.registro.append($0) }
            self.registro.append(r.ok ? r.respuesta : "Algo falló: \(r.respuesta)")
        }
    }
}

// MARK: - Formulario de materia nueva

struct FormNuevaMateria: View {
    @ObservedObject var s: Sesion
    @ObservedObject var m: Materias
    let z: CGFloat
    let cerrar: () -> Void
    @StateObject private var f = Datos()

    final class Datos: ObservableObject {
        @Published var nombre = ""
        @Published var descripcion = ""
        @Published var material: [URL] = []
        @Published var ajustes = AjustesMateria()
        @Published var error: String?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14 * z) {
            Text("Materia nueva").font(.system(size: 24 * z, weight: .bold, design: .rounded))
            CampoHoja(titulo: "Nombre (por ejemplo: Historia de los videojuegos)", texto: $f.nombre, z: z)
            Text("¿Qué quieres aprender y para qué?").font(.system(size: 14 * z, weight: .semibold))
            TextEditor(text: $f.descripcion)
                .font(.system(size: 15 * z)).scrollContentBackground(.hidden).frame(height: 120 * z)
                .padding(.horizontal, 8 * z).padding(.vertical, 8 * z)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10 * z))
                .overlay(RoundedRectangle(cornerRadius: 10 * z).strokeBorder(Color.white.opacity(0.12)))
            HStack {
                Button { elegirMaterial() } label: {
                    Label("Agregar tu material (PDF o texto)", systemImage: "doc.badge.plus")
                        .font(.system(size: 14 * z, weight: .semibold)).padding(.horizontal, 14 * z).padding(.vertical, 6 * z)
                }.buttonStyle(.glass)
                Spacer()
                if !f.material.isEmpty { Text("\(f.material.count) archivo\(f.material.count == 1 ? "" : "s")").font(.system(size: 13 * z)).foregroundStyle(.secondary) }
            }
            ForEach(f.material, id: \.self) { Text("• " + $0.lastPathComponent).font(.system(size: 13 * z)).foregroundStyle(.secondary) }
            HStack {
                Text("Teoría \(Int(f.ajustes.teoria)) %").font(.system(size: 15 * z, weight: .semibold))
                Slider(value: $f.ajustes.teoria, in: 0...100, step: 5)
                Text("Práctica \(100 - Int(f.ajustes.teoria)) %").font(.system(size: 15 * z, weight: .semibold)).foregroundStyle(Color.accentColor)
            }
            Stepper(value: $f.ajustes.duracion, in: 15...120, step: 5) {
                Text("Clases de \(f.ajustes.duracion) minutos").font(.system(size: 15 * z, weight: .semibold))
            }
            Text("Al crearla, Claude investiga fuentes confiables y arma el plan (temario y metas), como el de Oratoria. Tarda unos minutos.")
                .font(.system(size: 13 * z)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let e = f.error { Text(e).font(.system(size: 13 * z)).foregroundStyle(.orange) }
            HStack(spacing: 10 * z) {
                Spacer()
                Button(action: cerrar) { botonHoja("Cancelar", z) }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
                Button { crear() } label: {
                    Label("Crear y armar el plan", systemImage: "sparkles")
                        .font(.system(size: 14 * z, weight: .semibold)).padding(.horizontal, 14 * z).padding(.vertical, 6 * z)
                }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                    .disabled(f.nombre.trimmingCharacters(in: .whitespaces).isEmpty || f.descripcion.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(28 * z).frame(width: 600 * z)
        .buttonBorderShape(.capsule).controlSize(.large)   // la hoja no hereda la forma de los botones de la ventana
    }

    private func elegirMaterial() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        p.allowedContentTypes = [.pdf, .plainText, UTType(filenameExtension: "md") ?? .plainText]
        if p.runModal() == .OK { f.material += p.urls }
    }

    private func crear() {
        guard s.trabajando == nil else { f.error = "Claude todavía está trabajando en otra materia. Espera a que termine."; return }
        guard let u = m.crear(nombre: f.nombre, descripcion: f.descripcion, material: f.material, ajustes: f.ajustes) else {
            f.error = "No pude crearla: ¿ya hay una materia con ese nombre?"; return
        }
        cerrar()
        if s.usar(u) { s.armarPlan() }
        s.pantalla = .materia(u)
    }
}

// MARK: - Temario: ver, editar a mano o pedirle el cambio a Claude

struct TarjetaTemario: View {
    @ObservedObject var s: Sesion
    @ObservedObject var m: Materias
    let materia: Materia
    let z: CGFloat
    @StateObject private var e = Edicion()

    final class Edicion: ObservableObject {
        @Published var editando = false
        @Published var texto = ""
        @Published var pedido = ""
        @Published var bloques: [Bloque] = []
        @Published var secciones: [SeccionPlan] = []
        /// Qué secciones dejaste abiertas o cerradas (por título), para encontrarlas igual al volver.
        @Published var abiertas: [String: Bool] = [:]
    }

    private var claveAbiertas: String { "seccionesAbiertas:" + materia.url.lastPathComponent }

    /// Lee el plan una vez (al aparecer, al volver a la app y cuando Claude termina), no en cada redibujo.
    private func leerPlan() {
        let t = (try? String(contentsOf: materia.plan, encoding: .utf8)) ?? ""
        e.bloques = Bloque.leer(t.components(separatedBy: "\n"))
        e.secciones = SeccionPlan.armar(e.bloques)
        if e.abiertas.isEmpty { e.abiertas = UserDefaults.standard.dictionary(forKey: claveAbiertas) as? [String: Bool] ?? [:] }
    }

    /// El título principal (#) empieza abierto; las secciones de adentro, cerradas: así se ve el índice del plan.
    private func abierta(_ s: SeccionPlan) -> Bool { e.abiertas[s.titulo] ?? (s.nivel <= 1) }
    private func alternar(_ s: SeccionPlan) {
        withAnimation(.easeOut(duration: 0.15)) { e.abiertas[s.titulo] = !abierta(s) }
        UserDefaults.standard.set(e.abiertas, forKey: claveAbiertas)
    }

    private var puedePedir: Bool { !e.pedido.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && s.trabajando == nil }

    /// Caja para escribirle a Claude, como la de un chat: el mensaje y el botón de enviar.
    private var cajaPedido: some View {
        HStack(alignment: .bottom, spacing: 10 * z) {
            Image(systemName: "sparkles").font(.system(size: 15 * z)).foregroundStyle(Color.accentColor)
                .padding(.bottom, 7 * z)
            TextField("Escríbele a Claude un cambio al plan, p. ej. «agrega un tema de X después de la clase 3»",
                      text: $e.pedido, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 14 * z)).lineLimit(1...5)
                .padding(.vertical, 7 * z)
                .onSubmit { if puedePedir { pedir() } }
            Button(action: pedir) {
                Image(systemName: "arrow.up").font(.system(size: 14 * z, weight: .bold))
                    .foregroundStyle(puedePedir ? Color.white : Color.secondary)
                    .frame(width: 30 * z, height: 30 * z)
                    .background(Circle().fill(puedePedir ? Color.accentColor : Color.white.opacity(0.1)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain).disabled(!puedePedir).help("Enviar a Claude (Enter)")
        }
        .padding(.leading, 14 * z).padding(.trailing, 6 * z).padding(.vertical, 5 * z)
        .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 20 * z))
        .overlay(RoundedRectangle(cornerRadius: 20 * z).strokeBorder(Color.white.opacity(0.12)))
    }

    private var abierta: Bool { Carpeta.raiz.standardizedFileURL == materia.url.standardizedFileURL }

    var body: some View {
        VStack(alignment: .leading, spacing: 12 * z) {
            HStack {
                Text("TEMARIO Y CONTENIDO").font(.system(size: 11 * z, weight: .semibold)).kerning(1.2).foregroundStyle(.secondary)
                Spacer()
                if materia.tienePlan {
                    Button(e.editando ? "Guardar" : "Editar a mano") {
                        if e.editando { try? e.texto.write(to: materia.plan, atomically: true, encoding: .utf8); m.cargar(); leerPlan() }
                        else { e.texto = (try? String(contentsOf: materia.plan, encoding: .utf8)) ?? "" }
                        e.editando.toggle()
                    }.buttonStyle(.enlace(z)).font(.system(size: 12 * z, weight: .semibold))
                    if e.editando { Button("Cancelar") { e.editando = false }.buttonStyle(.enlace(z)).font(.system(size: 12 * z)).foregroundStyle(.secondary) }
                }
            }
            if s.trabajando != nil, abierta {
                HStack(spacing: 8 * z) { ProgressView().controlSize(.small); Text(s.trabajando ?? "") }.font(.system(size: 13 * z))
                Registro(s: s, z: z)
            }
            if !materia.tienePlan {
                Text("Esta materia todavía no tiene plan. Claude lee su CLAUDE.md (qué quieres aprender y para qué) y tu material, investiga fuentes confiables y arma el temario y las metas.")
                    .font(.system(size: 14 * z)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button { if s.usar(materia.url) { s.armarPlan() } } label: {
                    Label("Armar el plan con Claude", systemImage: "sparkles").font(.system(size: 15 * z, weight: .semibold)).padding(.horizontal, 16 * z).padding(.vertical, 9 * z)
                }.buttonStyle(.glassProminent).disabled(s.trabajando != nil || materia.esOratoria)
                Spacer(minLength: 0)
            } else if e.editando {
                TextEditor(text: $e.texto)
                    .font(.system(size: 13 * z, design: .monospaced)).scrollContentBackground(.hidden)
                    .frame(maxHeight: .infinity).padding(8 * z)
                    .background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 10 * z))
            } else {
                // solo esta parte se desplaza; cada título es una sección que se pliega
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6 * z) {
                        ForEach(e.secciones) { sec in vistaSeccion(sec) }
                    }
                    .padding(.trailing, 10 * z).padding(.bottom, 8 * z)
                }
                .frame(maxHeight: .infinity)
                cajaPedido
            }
        }
        .padding(18 * z).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20 * z))
        .onChange(of: s.trabajando) { _, t in if t == nil { m.cargar(); leerPlan() } }
        .onAppear(perform: leerPlan)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in leerPlan() }
    }

    /// Una sección del plan: su título se pulsa para plegarla o desplegarla; adentro van su texto y sus subsecciones.
    /// AnyView porque se llama a sí misma.
    private func vistaSeccion(_ sec: SeccionPlan) -> AnyView {
        let zz = z * 0.9
        guard !sec.titulo.isEmpty else { return AnyView(VistaPlan(bloques: sec.contenido, z: zz)) }
        let abre = abierta(sec)
        let tam: CGFloat = sec.nivel <= 1 ? 22 : sec.nivel == 2 ? 18 : 16
        return AnyView(VStack(alignment: .leading, spacing: 8 * z) {
            Button { alternar(sec) } label: {
                HStack(spacing: 8 * z) {
                    Image(systemName: "chevron.right").font(.system(size: tam * 0.6 * zz, weight: .bold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(abre ? 90 : 0)).frame(width: 14 * zz)
                    Text((try? AttributedString(markdown: sec.titulo)) ?? AttributedString(sec.titulo))
                        .font(.system(size: tam * zz, weight: .bold)).multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4 * z).contentShape(Rectangle())
            }
            .buttonStyle(EstiloHover(margen: 8 * z))
            if abre {
                VStack(alignment: .leading, spacing: 8 * z) {
                    if !sec.contenido.isEmpty { VistaPlan(bloques: sec.contenido, z: zz) }
                    ForEach(sec.hijas) { vistaSeccion($0) }
                }
                .padding(.leading, 22 * zz)
            }
        })
    }

    private func pedir() {
        guard puedePedir, s.usar(materia.url) else { return }
        s.cambiarPlan(e.pedido)
        e.pedido = ""
    }
}


/// El plan, solo para leer: texto normal de SwiftUI (no una vista de texto seleccionable por párrafo, como en la clase),
/// así un plan de cientos de líneas no traba el scroll.
struct VistaPlan: View {
    let bloques: [Bloque]
    let z: CGFloat

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 10 * z) {
            ForEach(Array(bloques.enumerated()), id: \.offset) { _, b in vista(b) }
        }
    }

    private func vineta(_ marca: String, _ t: String, _ n: Int) -> some View {
        HStack(alignment: .top, spacing: 8 * z) {
            Text(marca).font(.system(size: 14 * z, weight: .semibold)).foregroundStyle(.secondary).frame(minWidth: 16 * z, alignment: .trailing)
            TextoMD(texto: t, z: z, tam: 14)
        }.padding(.leading, CGFloat(n) * 20 * z)
    }

    @ViewBuilder private func vista(_ b: Bloque) -> some View {
        switch b {
        case .titulo(let n, let t, _):
            TextoMD(texto: t, z: z, tam: n <= 1 ? 22 : n == 2 ? 18 : 16, peso: .bold).padding(.top, 8 * z)
        case .texto(let t, _):
            TextoMD(texto: t, z: z, tam: 14)
        case .item(let n, let m, let t, _):
            vineta(m, t, n)
        case .tarea(let n, let t, let hecha, _):
            vineta(hecha ? "☑" : "☐", t, n)
        case .cita(let n, let t, _):
            HStack(spacing: 10 * z) {
                RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.35)).frame(width: 3 * z)
                TextoMD(texto: t, z: z, tam: 14).foregroundStyle(Color.suave)
            }.padding(.leading, CGFloat(n) * 20 * z)
        case .codigo(let c, _):
            Text(c).font(.system(size: 12 * z, design: .monospaced))
        case .tabla(let filas, _):
            Grid(alignment: .topLeading, horizontalSpacing: 12 * z, verticalSpacing: 6 * z) {
                ForEach(Array(filas.enumerated()), id: \.offset) { i, f in
                    GridRow { ForEach(Array(f.enumerated()), id: \.offset) { _, c in TextoMD(texto: c, z: z, tam: 13, peso: i == 0 ? .semibold : .regular) } }
                    if i == 0 { Divider().gridCellUnsizedAxes(.horizontal) }
                }
            }
        case .detalles(let r, let hijos, _):
            VStack(alignment: .leading, spacing: 6 * z) {
                Text(r).font(.system(size: 14 * z, weight: .semibold))
                VistaPlan(bloques: hijos, z: z).padding(.leading, 12 * z)
            }
        case .regla:
            Divider()
        case .campo:
            EmptyView()
        }
    }
}

/// El plan partido en secciones por sus títulos (#, ##, ###…): cada título abre una sección que llega hasta el siguiente
/// título de su mismo nivel o de uno mayor, y los de nivel menor quedan adentro como subsecciones.
struct SeccionPlan: Identifiable {
    let id: Int
    let nivel: Int
    let titulo: String
    var contenido: [Bloque] = []
    var hijas: [SeccionPlan] = []

    static func armar(_ bloques: [Bloque]) -> [SeccionPlan] {
        var i = 0, n = 0
        var raiz = SeccionPlan(id: -1, nivel: 0, titulo: "")
        llenar(&raiz, bloques, &i, &n)
        // lo que va antes del primer título se muestra suelto, sin encabezado
        let suelto = raiz.contenido.isEmpty ? [] : [SeccionPlan(id: 0, nivel: 0, titulo: "", contenido: raiz.contenido)]
        return suelto + raiz.hijas
    }

    private static func llenar(_ s: inout SeccionPlan, _ bloques: [Bloque], _ i: inout Int, _ n: inout Int) {
        while i < bloques.count {
            if case .titulo(let nivel, let t, _) = bloques[i] {
                if nivel <= s.nivel { return }
                i += 1; n += 1
                var hija = SeccionPlan(id: n, nivel: nivel, titulo: t)
                llenar(&hija, bloques, &i, &n)
                s.hijas.append(hija)
            } else {
                s.contenido.append(bloques[i]); i += 1
            }
        }
    }
}
