import SwiftUI
import AppKit

// MARK: - Lo que la app necesita para funcionar en cualquier Mac

/// Claude Code (con la sesión iniciada: la suscripción de la persona) y las herramientas de voz (Python + el modelo de
/// transcripción). Se revisa al abrir la pantalla de materias; si algo falta, una tarjeta lo instala paso a paso.
final class Requisitos: ObservableObject {
    enum Claude { case revisando, falta, sinSesion, listo }
    @Published var claude: Claude = .revisando
    @Published var voz = false
    @Published var instalando: String?
    @Published var registro: [String] = []

    var listos: Bool { claude == .listo && voz }

    static var modeloDescargado: Bool {
        let hub = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface/hub/models--nyrahealth--CrisperWhisper")
        return FileManager.default.fileExists(atPath: hub.path)
    }

    @MainActor func revisar() async {
        voz = FileManager.default.isExecutableFile(atPath: Herramientas.python) && Self.modeloDescargado
        guard let c = Herramientas.claude else { claude = .falta; return }
        let r = await Herramientas.correr(c, ["auth", "status"])
        let datos = r.salida.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        claude = (datos?["loggedIn"] as? Bool) == true ? .listo : .sinSesion
    }

    /// El instalador oficial de Claude Code (lo deja en ~/.local/bin).
    @MainActor func instalarClaude() {
        correr("Instalando Claude Code…", "/bin/bash", ["-c", "curl -fsSL https://claude.ai/install.sh | bash"])
    }

    /// Iniciar sesión pide el navegador: se abre en la Terminal, donde Claude Code lo guía.
    func iniciarSesion() {
        let comando = (Herramientas.claude ?? "claude") + " auth login"
        let script = "tell application \"Terminal\" to do script \"\(comando)\"\ntell application \"Terminal\" to activate"
        NSAppleScript(source: script)?.executeAndReturnError(nil)
    }

    /// Python, las librerías y el modelo, con el instalador que trae la app.
    @MainActor func instalarVoz() {
        guard let s = Bundle.main.resourceURL?.appendingPathComponent("herramientas/instalar.sh").path else { return }
        correr("Instalando las herramientas de voz (unos minutos; el modelo pesa ~3 GB)…", "/bin/bash", [s])
    }

    @MainActor private func correr(_ titulo: String, _ programa: String, _ args: [String]) {
        guard instalando == nil else { return }
        instalando = titulo; registro = []
        Task { @MainActor in
            let r = await Herramientas.correr(programa, args) { [weak self] l in
                self?.registro.append(l)
                if (self?.registro.count ?? 0) > 200 { self?.registro.removeFirst() }
            }
            if r.codigo != 0 { self.registro.append("Algo falló (código \(r.codigo)). Revisa tu conexión y vuelve a intentarlo.") }
            self.instalando = nil
            await self.revisar()
        }
    }
}

/// «Antes de empezar»: sale arriba de las materias mientras falte algo.
struct TarjetaRequisitos: View {
    @ObservedObject var r: Requisitos
    let z: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 12 * z) {
            Text("ANTES DE EMPEZAR").font(.system(size: 11 * z, weight: .semibold)).kerning(1.2).foregroundStyle(.secondary)
            fila(ok: r.claude == .listo, titulo: "Claude Code con tu suscripción de Claude",
                 detalle: r.claude == .falta ? "Hace falta para armar planes, crear clases y evaluarte."
                    : r.claude == .sinSesion ? "Está instalado, pero falta iniciar sesión con tu cuenta de Claude."
                    : r.claude == .revisando ? "Revisando…" : "Listo.") {
                if r.claude == .falta { boton("Instalar") { r.instalarClaude() } }
                if r.claude == .sinSesion { boton("Iniciar sesión") { r.iniciarSesion() } }
            }
            fila(ok: r.voz, titulo: "Herramientas de voz",
                 detalle: r.voz ? "Listo." : "Para transcribir y analizar tus respuestas grabadas. Se instalan una vez (~5 GB).") {
                if !r.voz { boton("Instalar") { r.instalarVoz() } }
            }
            if let t = r.instalando {
                HStack(spacing: 8 * z) { ProgressView().controlSize(.small); Text(t).font(.system(size: 13 * z)) }
            }
            if let ultima = r.registro.last {
                Text(ultima).font(.system(size: 12 * z, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack {
                Spacer()
                Button { Task { await r.revisar() } } label: { botonHoja("Comprobar de nuevo", z) }.buttonStyle(.glass)
            }
        }
        .padding(18 * z).frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20 * z))
    }

    private func fila<B: View>(ok: Bool, titulo: String, detalle: String, @ViewBuilder boton: () -> B) -> some View {
        HStack(spacing: 12 * z) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle").font(.system(size: 18 * z))
                .foregroundStyle(ok ? Color.afinado : Color.secondary)
            VStack(alignment: .leading, spacing: 2 * z) {
                Text(titulo).font(.system(size: 15 * z, weight: .semibold))
                Text(detalle).font(.system(size: 13 * z)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            boton()
        }
    }

    private func boton(_ t: String, _ accion: @escaping () -> Void) -> some View {
        Button(action: accion) { botonHoja(t, z) }.buttonStyle(.glassProminent).disabled(r.instalando != nil)
    }
}
