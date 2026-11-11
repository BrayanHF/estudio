import AppKit
import SwiftUI

/// La franja de arriba de la ventana. La app esconde la barra de título para que su contenido llegue hasta arriba, y así
/// se perdía el doble clic del sistema. Esta franja va detrás de todo: solo recibe los clics que caen en un espacio vacío
/// (los botones siguen igual). Doble clic hace lo que diga Ajustes del Sistema (Escritorio y Dock → «Hacer doble clic en
/// la barra de título de una ventana para»): llenar la pantalla, zoom o minimizar. Arrastrar desde ahí mueve la ventana.
struct BarraDeTitulo: NSViewRepresentable {
    func makeNSView(context: Context) -> Vista { Vista.escucharDobleClic(); return Vista() }
    func updateNSView(_ v: Vista, context: Context) {}

    final class Vista: NSView {
        /// Alto de la zona de arriba donde el doble clic llena la ventana (donde iría la barra de título).
        static let altoBanda: CGFloat = 36
        private static var monitor: Any?

        /// La franja de atrás no basta: en pantallas con ScrollView de lado a lado (las materias) el scroll se queda con
        /// los clics y la franja nunca los recibe. Este escucha ve el doble clic antes que cualquier vista, en los 36 px
        /// de arriba, y deja pasar los que caen en los botones de la ventana (cerrar, minimizar, zoom).
        static func escucharDobleClic() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { e in
                guard e.clickCount == 2, let w = e.window, w.styleMask.contains(.fullSizeContentView),
                      !w.styleMask.contains(.fullScreen) else { return e }
                let p = e.locationInWindow
                guard p.y >= w.frame.height - altoBanda else { return e }
                if let marco = w.contentView?.superview, marco.hitTest(p) is NSControl { return e }   // semáforo
                dobleClic(w)
                return nil
            }
        }
        /// El tamaño de antes de llenar la pantalla, para volver a él con otro doble clic.
        private static var antes: [Int: NSRect] = [:]

        override func mouseDown(with event: NSEvent) {
            guard let w = window else { return }
            if event.clickCount == 2 { Self.dobleClic(w) } else { w.performDrag(with: event) }
        }

        static func dobleClic(_ w: NSWindow) {
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Fill" {
            case "Minimize": w.miniaturize(nil)
            case "None": break
            case "Maximize": w.zoom(nil)
            default:   // «Llenar»: ocupa la pantalla sin el Dock ni la barra de menús; otro doble clic la devuelve
                guard let pantalla = w.screen?.visibleFrame else { return }
                let llena = abs(w.frame.width - pantalla.width) < 2 && abs(w.frame.height - pantalla.height) < 2
                if llena, let previo = antes[w.windowNumber] {
                    w.setFrame(previo, display: true, animate: true)
                    antes[w.windowNumber] = nil
                } else if !llena {
                    antes[w.windowNumber] = w.frame
                    w.setFrame(pantalla, display: true, animate: true)
                }
            }
        }
    }
}
