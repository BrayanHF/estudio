import Foundation
import AVFoundation

/// Graba el micrófono en WAV (mono, 48 kHz, 16 bits: el mismo formato que se exportaba desde Audacity)
/// y reproduce lo grabado.
final class Grabador: ObservableObject {
    @Published private(set) var grabando: String?     // nombre del archivo que se está grabando
    @Published private(set) var sonando: String?
    @Published private(set) var nivel: Float = 0      // 0…1, para el medidor
    @Published private(set) var segundos: Double = 0
    @Published var error: String?
    @Published private(set) var cargado: String?      // grabación abierta para escuchar (sonando o en pausa)
    @Published private(set) var posicion: Double = 0  // segundo en que va lo que se escucha
    var arrastrando = false                           // mientras mueves la barra, el reloj no la pisa
    var alEmpezar: ((URL) -> Void)?                   // empieza una grabación (la transcripción vieja ya no sirve)
    var alTerminar: ((URL) -> Void)?                  // quedó un WAV completo: se puede transcribir
    private var destino: URL?

    /// Ganancia de la grabación en dB. El micrófono (fifine USB) entrega la voz muy baja: unos −35 dBFS de
    /// promedio, cuando la voz hablada suele ir entre −18 y −20. Se sube antes de guardar, como el +12 dB de Audacity.
    static let ganancias: [Double] = [0, 3, 6, 9, 12, 15, 18]
    @Published var ganancia: Double = UserDefaults.standard.object(forKey: "gananciaGrabacion") as? Double ?? 12 {
        didSet { UserDefaults.standard.set(ganancia, forKey: "gananciaGrabacion") }
    }
    private var factor: Float = 1   // la ganancia de la grabación en curso (no cambia a mitad de una toma)

    private let engine = AVAudioEngine()
    private var archivo: AVAudioFile?
    private var conversor: AVAudioConverter?
    private var inicio = Date()
    private var reloj: Timer?
    private var player: AVAudioPlayer?
    private var cambio: NSObjectProtocol?
    private var microfono: AudioDeviceID?   // el de la toma en curso
    private let formatoArchivo = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!

    func url(_ nombre: String, fecha: String) -> URL {
        Carpeta.grabacionesDel(fecha).appendingPathComponent("\(fecha)_\(nombre).wav")
    }

    func existe(_ nombre: String, fecha: String) -> Bool { FileManager.default.fileExists(atPath: url(nombre, fecha: fecha).path) }

    func duracion(_ nombre: String, fecha: String) -> Double? {
        guard let f = try? AVAudioFile(forReading: url(nombre, fecha: fecha)) else { return nil }
        return Double(f.length) / f.fileFormat.sampleRate
    }

    func grabar(_ nombre: String, fecha: String) {
        detener()
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            DispatchQueue.main.async {
                guard ok else { self.error = L("Sin permiso de micrófono. Actívalo en Ajustes → Privacidad → Micrófono."); return }
                self.empezar(nombre, fecha: fecha)
            }
        }
    }

    private func empezar(_ nombre: String, fecha: String) {
        let destino = url(nombre, fecha: fecha)
        try? FileManager.default.createDirectory(at: destino.deletingLastPathComponent(), withIntermediateDirectories: true)
        let ajustes: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1,
                                      AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        do {
            archivo = try AVAudioFile(forWriting: destino, settings: ajustes, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch { self.error = L("No pude crear el archivo: \(error.localizedDescription)"); return }
        factor = Float(pow(10, ganancia / 20))
        microfono = Microfono.elegido()
        guard conectar() else { self.error = L("No pude usar el micrófono."); archivo = nil; return }
        // al conectar audífonos Bluetooth macOS para el motor aunque el micrófono sea el mismo: se reconecta y la toma
        // sigue. Si de verdad cambió el micrófono (desconectaste el fifine), la grabación se para y se avisa.
        cambio = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.reconectar() }
        }
        error = nil
        grabando = nombre
        self.destino = destino
        alEmpezar?(destino)
        inicio = Date(); segundos = 0
        reloj = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.segundos = Date().timeIntervalSince(self.inicio)
        }
    }

    /// Fija el micrófono (nunca el de unos audífonos Bluetooth si hay otro), pone el tap y arranca.
    private func conectar() -> Bool {
        Microfono.fijar(en: engine)
        let input = engine.inputNode
        let formato = input.outputFormat(forBus: 0)
        guard formato.sampleRate > 0 else { return false }
        conversor = AVAudioConverter(from: formato, to: formatoArchivo)
        input.installTap(onBus: 0, bufferSize: 4096, format: formato) { [weak self] buf, _ in self?.escribir(buf) }
        do { try engine.start(); return true } catch { input.removeTap(onBus: 0); return false }
    }

    private func reconectar() {
        guard grabando != nil, !engine.isRunning || Microfono.elegido() != microfono else { return }
        guard Microfono.elegido() == microfono else {
            detener()
            error = L("La grabación se cortó porque cambió el micrófono. Vuelve a grabarla.")
            return
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if !conectar() {
            detener()
            error = L("La grabación se cortó porque el micrófono dejó de responder. Vuelve a grabarla.")
        }
    }

    private func escribir(_ buf: AVAudioPCMBuffer) {
        guard let conversor, let archivo else { return }
        let cap = AVAudioFrameCount(Double(buf.frameLength) * 48000 / buf.format.sampleRate) + 64
        guard let salida = AVAudioPCMBuffer(pcmFormat: formatoArchivo, frameCapacity: cap) else { return }
        var entregado = false
        conversor.convert(to: salida, error: nil) { _, estado in
            if entregado { estado.pointee = .noDataNow; return nil }
            entregado = true; estado.pointee = .haveData; return buf
        }
        if let ch = salida.floatChannelData?[0], salida.frameLength > 0 {
            // ganancia y, arriba de 0,9, un limitador suave: los picos se redondean en vez de saturarse (sin chasquidos)
            let g = factor
            for i in 0..<Int(salida.frameLength) {
                let y = ch[i] * g, a = abs(y)
                ch[i] = a <= 0.9 ? y : (y < 0 ? -1 : 1) * (0.9 + 0.1 * tanh((a - 0.9) / 0.1))
            }
        }
        try? archivo.write(from: salida)
        if let ch = salida.floatChannelData?[0], salida.frameLength > 0 {
            var pico: Float = 0
            for i in 0..<Int(salida.frameLength) { pico = max(pico, abs(ch[i])) }
            DispatchQueue.main.async { self.nivel = self.nivel * 0.6 + pico * 0.4 }
        }
    }

    func detener() {
        if grabando != nil {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            archivo = nil   // al soltarlo se cierra y queda el WAV completo
            if let cambio { NotificationCenter.default.removeObserver(cambio); self.cambio = nil }
            grabando = nil
            nivel = 0
            reloj?.invalidate()
            if let d = destino { destino = nil; alTerminar?(d) }
        }
        player?.stop(); sonando = nil; cargado = nil; posicion = 0
    }

    /// Abre la grabación para escucharla, sin darle play, si no es la que ya está abierta.
    private func cargar(_ nombre: String, fecha: String) -> Bool {
        if cargado == nombre, player != nil { return true }
        detener()
        player = try? AVAudioPlayer(contentsOf: url(nombre, fecha: fecha))
        player?.prepareToPlay()
        cargado = player == nil ? nil : nombre
        posicion = 0
        return player != nil
    }

    /// Play o pausa. La pausa guarda dónde ibas; al terminar vuelve al inicio.
    func escuchar(_ nombre: String, fecha: String) {
        if sonando == nombre { player?.pause(); sonando = nil; return }
        guard cargar(nombre, fecha: fecha), let player else { return }
        if player.currentTime >= player.duration - 0.05 { player.currentTime = 0 }
        player.play()
        sonando = nombre
        let n = nombre
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            guard self.sonando == n, let p = self.player else { t.invalidate(); return }
            if !self.arrastrando { self.posicion = p.currentTime }
            if !p.isPlaying {   // llegó al final
                self.sonando = nil; self.posicion = 0; p.currentTime = 0; t.invalidate()
            }
        }
    }

    /// Salta a un segundo de la grabación (la barra de tiempo). Si estaba sonando, sigue sonando desde ahí.
    func mover(_ nombre: String, fecha: String, a segundo: Double) {
        guard cargar(nombre, fecha: fecha), let player else { return }
        player.currentTime = max(0, min(segundo, player.duration))
        posicion = player.currentTime
    }
}
