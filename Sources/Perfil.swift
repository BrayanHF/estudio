import SwiftUI

// MARK: - Quién estudia

/// La persona que usa la app: se pregunta la primera vez y Claude la tiene en cuenta en todo (crear, evaluar, armar planes).
/// Se guarda en ~/Library/Application Support/Estudio/perfil.json; nada de esto va en el código.
struct Perfil: Codable, Equatable {
    var nombre = ""
    /// A qué se dedica, qué ya sabe, su contexto.
    var sobreMi = ""
    /// Qué quiere lograr estudiando.
    var metas = ""
    /// En qué idioma quiere las clases y las evaluaciones (p. ej. «español», «español de Colombia», «English»).
    var idioma = "español"
    /// Dónde van sus materias (una carpeta por materia).
    var carpeta = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Estudio").path

    static let archivo = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Estudio/perfil.json")

    /// El perfil guardado; nil la primera vez (entonces la app muestra la bienvenida).
    static var actual: Perfil? = {
        (try? Data(contentsOf: archivo)).flatMap { try? JSONDecoder().decode(Perfil.self, from: $0) }
    }()

    func guardar() {
        try? FileManager.default.createDirectory(at: Self.archivo.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: carpeta, withIntermediateDirectories: true)
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? e.encode(self).write(to: Self.archivo, options: .atomic)
        Perfil.actual = self
    }

    /// Cómo se le nombra en los pedidos a Claude.
    static var trato: String {
        let n = actual?.nombre.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return n.isEmpty ? "la persona que estudia" : n
    }

    /// El código del idioma para la transcripción (Whisper): es, en, pt, fr, de, it.
    static var codigoIdioma: String {
        let t = idioma.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        let codigos: [(String, String)] = [("ingl", "en"), ("english", "en"), ("portug", "pt"), ("franc", "fr"), ("french", "fr"),
                                           ("alem", "de"), ("german", "de"), ("ital", "it")]
        return codigos.first { t.contains($0.0) }?.1 ?? "es"
    }

    static var idioma: String { actual?.idioma.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "español" }

    /// Lo que Claude sabe de la persona: va en las instrucciones de todo pedido.
    static var contexto: String {
        guard let p = actual else { return "" }
        var t = "Quien estudia en la app Estudio"
        if let n = p.nombre.nonEmpty { t += " se llama \(n)" }
        t += ". Aprende por su cuenta, con la IA como tutor, y practica la oratoria en todas las materias: responde todo hablando y grabando."
        if let s = p.sobreMi.nonEmpty { t += "\nSobre esta persona: \(s)" }
        if let m = p.metas.nonEmpty { t += "\nQué quiere lograr: \(m)" }
        t += "\nEscribe las clases, las evaluaciones y los mensajes en \(idioma)."
        return t
    }
}

extension String {
    var nonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

// MARK: - Bienvenida (primer uso) y editar el perfil

struct VistaPerfil: View {
    @ObservedObject var s: Sesion
    @ObservedObject var m: Materias
    let z: CGFloat
    /// true la primera vez (sin perfil): no hay botón de cancelar.
    let bienvenida: Bool
    let cerrar: () -> Void
    @StateObject private var f = Datos()

    final class Datos: ObservableObject {
        @Published var p = Perfil.actual ?? Perfil()
        @Published var cargado = false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14 * z) {
            Text(bienvenida ? "Bienvenido a Estudio" : "Tu perfil").font(.system(size: 28 * z, weight: .bold, design: .rounded))
            if bienvenida {
                Text("Cuéntale a la app quién eres y qué quieres lograr. Claude lo usa para armar tus planes, tus clases y tus evaluaciones. Todo se responde hablando: en cada materia practicas también la oratoria.")
                    .font(.system(size: 14 * z)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            etiqueta("¿Cómo te llamas?")
            CampoHoja(titulo: "Tu nombre", texto: $f.p.nombre, z: z)
            etiqueta("¿A qué te dedicas? ¿Qué ya sabes?")
            cuadro($f.p.sobreMi)
            etiqueta("¿Qué quieres lograr estudiando?")
            cuadro($f.p.metas)
            etiqueta("Idioma de tus clases")
            CampoHoja(titulo: "Por ejemplo: español, español de Colombia, English", texto: $f.p.idioma, z: z)
            etiqueta("Dónde se guardan tus materias")
            HStack(spacing: 10 * z) {
                Text(f.p.carpeta).font(.system(size: 13 * z, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Spacer()
                Button { elegirCarpeta() } label: { botonHoja("Cambiar", z) }.buttonStyle(.glass)
            }
            HStack(spacing: 10 * z) {
                Spacer()
                if !bienvenida { Button(action: cerrar) { botonHoja("Cancelar", z) }.buttonStyle(.glass).keyboardShortcut(.cancelAction) }
                Button { guardar() } label: { botonHoja(bienvenida ? "Empezar" : "Guardar", z) }
                    .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction).disabled(f.p.nombre.nonEmpty == nil)
            }
        }
        .padding(30 * z).frame(width: 620 * z)
        .buttonBorderShape(.capsule).controlSize(.large)
    }

    private func etiqueta(_ t: String) -> some View {
        Text(traducir(t)).font(.system(size: 14 * z, weight: .semibold)).padding(.top, 2 * z)
    }

    private func cuadro(_ texto: Binding<String>) -> some View {
        TextEditor(text: texto)
            .font(.system(size: 15 * z)).scrollContentBackground(.hidden).frame(height: 70 * z)
            .padding(8 * z)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10 * z))
            .overlay(RoundedRectangle(cornerRadius: 10 * z).strokeBorder(Color.white.opacity(0.12)))
    }

    private func elegirCarpeta() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.directoryURL = URL(fileURLWithPath: f.p.carpeta).deletingLastPathComponent()
        p.prompt = L("Usar esta carpeta")
        if p.runModal() == .OK, let u = p.url { f.p.carpeta = u.path }
    }

    private func guardar() {
        f.p.guardar()
        m.cargar()
        Carpeta.elegirInicial()
        s.recargar()
        cerrar()
    }
}
