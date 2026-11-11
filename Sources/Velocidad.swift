import AVFoundation
import Foundation

/// Tu velocidad al hablar, medida en tus grabaciones de las clases: palabras de cada transcripción entre la
/// duración de su audio (con las pausas, como sonaría narrando), de los últimos 14 días. Se calcula una vez al día
/// (al abrir la app) y al evaluar cada clase, y se guarda en velocidad-al-hablar.json: Guion la lee de ahí.
enum Velocidad {
    /// Junto a las herramientas de voz, en los datos de la app (Guion la lee de ahí).
    static let archivo = Herramientas.carpeta.deletingLastPathComponent().appendingPathComponent("velocidad-al-hablar.json")
    static let dias = 14

    struct Medida: Codable {
        let fecha: String               // día en que se calculó
        let palabrasPorMinuto: Double
        let minutos: Double             // de audio medido
        let grabaciones: Int
        let dias: Int
    }

    /// La última medida guardada.
    static func leer() -> Medida? {
        (try? Data(contentsOf: archivo)).flatMap { try? JSONDecoder().decode(Medida.self, from: $0) }
    }

    /// `siempre`: recalcula aunque ya esté la de hoy (al terminar de evaluar una clase hay grabaciones nuevas).
    static func actualizar(siempre: Bool = false) {
        let hoy = Carpeta.hoy()
        if !siempre, let d = try? Data(contentsOf: archivo),
           let m = try? JSONDecoder().decode(Medida.self, from: d), m.fecha == hoy { return }
        Task.detached(priority: .utility) {
            guard let m = medir(hoy: hoy) else { return }
            let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? e.encode(m).write(to: archivo, options: .atomic)
        }
    }

    /// nil si hay menos de 2 minutos de muestra.
    private static func medir(hoy: String) -> Medida? {
        let fm = FileManager.default
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let desde = f.string(from: Date().addingTimeInterval(-Double(dias) * 86400))
        // todas las materias cuentan: en cualquiera se practica hablar
        let materias = ((try? fm.contentsOfDirectory(at: Materias.raiz, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
        let carpetas = materias.flatMap { m in
            ((try? fm.contentsOfDirectory(at: m.appendingPathComponent("grabaciones"), includingPropertiesForKeys: nil)) ?? [])
        }.filter { $0.lastPathComponent.prefix(10) >= desde }
        var palabras = 0, segundos = 0.0, n = 0
        for c in carpetas {
            for wav in (try? fm.contentsOfDirectory(at: c, includingPropertiesForKeys: nil)) ?? [] where wav.pathExtension == "wav" {
                guard let p = contar(wav.deletingPathExtension().appendingPathExtension("txt")),
                      let a = try? AVAudioFile(forReading: wav) else { continue }
                let s = Double(a.length) / a.fileFormat.sampleRate
                // fuera las pruebas de micrófono, la sirena y lo casi vacío
                guard s >= 5, p >= 10 else { continue }
                palabras += p; segundos += s; n += 1
            }
        }
        guard segundos >= 120 else { return nil }
        return Medida(fecha: hoy, palabrasPorMinuto: (Double(palabras) / (segundos / 60) * 10).rounded() / 10,
                      minutos: (segundos / 60 * 10).rounded() / 10, grabaciones: n, dias: dias)
    }

    /// Palabras de una transcripción de transcribir.py: "# título" y luego líneas "[m:ss.s] texto".
    private static func contar(_ txt: URL) -> Int? {
        guard let t = try? String(contentsOf: txt, encoding: .utf8) else { return nil }
        return t.split(separator: "\n").filter { !$0.hasPrefix("#") }.reduce(0) { suma, linea in
            let sinTiempo = linea.hasPrefix("[") ? linea.drop { $0 != "]" }.dropFirst() : linea[...]
            return suma + sinTiempo.split(whereSeparator: \.isWhitespace).count
        }
    }
}
