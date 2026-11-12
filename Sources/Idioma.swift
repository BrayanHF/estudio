import Foundation

// Textos de la interfaz en el idioma de la app (Resources/<idioma>.lproj/Localizable.strings).
// Las claves son los propios textos en español.

/// Un texto con valores (`"Algo falló: \(x)"` busca la clave "Algo falló: %@").
func L(_ v: String.LocalizationValue) -> String { String(localized: v) }

/// Un texto que llega en una variable (títulos de los ayudantes de vista, nombres de ejercicios…):
/// si está en la tabla se traduce, si no queda igual. No aplica formatos.
func traducir(_ s: String) -> String { Bundle.main.localizedString(forKey: s, value: s, table: nil) }

/// La app está en inglés (la eligió en el menú Estudio → Idioma de la app).
var appEnIngles: Bool { Bundle.main.preferredLocalizations.first == "en" }

/// Nombre de una nota: en español DO, RE, MI…; en inglés C, D, E…
func nota(_ s: String) -> String {
    guard appEnIngles else { return s }
    for (es, en) in [("SOL", "G"), ("DO", "C"), ("RE", "D"), ("MI", "E"), ("FA", "F"), ("LA", "A"), ("SI", "B")] where s.hasPrefix(es) {
        return en + s.dropFirst(es.count)
    }
    return s
}
