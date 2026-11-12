import SwiftUI
import AppKit
import AVFoundation
import Accelerate
import CoreML

// MARK: - Datos del calentamiento

struct Nota: Decodable { let t: Double; let e: Double; let m: Int; let n: String; let x: Int }
struct Ejercicio: Decodable { let name: String; let s: Double; let e: Double }
struct Datos: Decodable {
    let ejercicios: [Ejercicio]; let notas: [Nota]
    var afinacion: Double? = nil   // cents que está corrido el piano respecto a LA = 440 (medido del audio)
}

let SOLF = ["DO", "DO♯", "RE", "MI♭", "MI", "FA", "FA♯", "SOL", "LA♭", "LA", "SI♭", "SI"]
let NATURALES: Set<Int> = [0, 2, 4, 5, 7, 9, 11]

// MARK: - Colores

extension Color {
    // fondo oscuro (casi negro, con un toque azul pizarra) que se tiñe sobre el vidrio de la ventana
    static let fondo = Color(red: 0.06, green: 0.07, blue: 0.09)
    static let fondo2 = Color(red: 0.11, green: 0.12, blue: 0.16)
    static let crema = Color.white   // notas y énfasis
    static let suave = Color(red: 0.86, green: 0.88, blue: 0.92)
    static let afinado = Color(red: 0.49, green: 0.88, blue: 0.54)
    static let desafinado = Color(red: 1.0, green: 0.70, blue: 0.36)
}

// MARK: - Detector de tono sobre el micrófono (CREPE o YIN)

enum ModoDetector: String, CaseIterable { case crepe = "CREPE", yin = "YIN" }

final class DetectorTono {
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "afinador.tono", qos: .userInteractive)
    private let lock = NSLock()
    private var ventana = [Float](repeating: 0, count: 4096)   // YIN: audio a la frecuencia del micrófono
    private var ventana16: [Float] = []                          // CREPE: audio a 16 kHz
    private var pendientes = 0
    private var historial: [Double] = []
    private var ultimo: (midi: Double, cuando: Date)?
    private(set) var activo = false
    var modo: ModoDetector = .crepe
    private var modelo: MLModel?
    private var conversor: AVAudioConverter?
    private let formato16 = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    /// Lo que tarda CREPE en analizar 10 ms de audio, para vigilar que no se sature el Mac.
    private(set) var msPorAnalisis: Double = 0

    private var cambio: NSObjectProtocol?

    /// Suelta el micrófono (al salir del calentamiento), para que la clase pueda grabar sin cortes.
    func detener() {
        guard activo else { return }
        if let cambio { NotificationCenter.default.removeObserver(cambio); self.cambio = nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        activo = false
        lock.lock(); historial.removeAll(); ultimo = nil; lock.unlock()
    }

    func arrancar(_ listo: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            guard ok else { DispatchQueue.main.async { listo(false) }; return }
            let modelo = DetectorTono.cargarCrepe()
            DispatchQueue.main.async {
                self.modelo = modelo
                guard self.conectar() else { listo(false); return }
                self.activo = true
                // al conectar o quitar audífonos (o cambiar el micrófono), macOS para el motor: se vuelve a conectar solo
                self.cambio = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: self.engine,
                                                                     queue: .main) { [weak self] _ in
                    // espera a que el dispositivo nuevo termine de aparecer
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.reconectar() }
                }
                listo(true)
            }
        }
    }

    /// Fija el micrófono (nunca el de unos audífonos Bluetooth si hay otro), pone el tap y arranca.
    private func conectar() -> Bool {
        Microfono.fijar(en: engine)
        let input = engine.inputNode
        let formato = input.outputFormat(forBus: 0)
        let sr = formato.sampleRate
        guard sr > 0 else { return false }
        conversor = AVAudioConverter(from: formato, to: formato16)
        input.installTap(onBus: 0, bufferSize: 1024, format: formato) { buf, _ in
            guard let ch = buf.floatChannelData?[0] else { return }
            if self.modo == .yin {
                let nuevos = Array(UnsafeBufferPointer(start: ch, count: Int(buf.frameLength)))
                self.queue.async { self.procesarYIN(nuevos, sr: sr) }
            } else if let a16 = self.a16kHz(buf, sr: sr) {
                self.queue.async { self.procesarCREPE(a16) }
            }
        }
        do { try engine.start(); return true } catch { input.removeTap(onBus: 0); return false }
    }

    private func reconectar() {
        guard activo else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock(); historial.removeAll(); ultimo = nil; lock.unlock()
        if !conectar() {   // a veces el dispositivo tarda más: un segundo intento
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, self.activo, !self.engine.isRunning else { return }
                _ = self.conectar()
            }
        }
    }

    /// Tono cantado ahora mismo, en semitonos MIDI (nil si hay silencio).
    func actual() -> Double? {
        lock.lock(); defer { lock.unlock() }
        guard let u = ultimo, Date().timeIntervalSince(u.cuando) < 0.18 else { return nil }
        return u.midi
    }

    private func publicar(_ m: Double?) {
        lock.lock(); defer { lock.unlock() }
        // un instante sin voz no corta la línea: en los trinos (RRRR, BURBUJAS, LENGUA) el sonido se
        // interrumpe muchas veces por segundo. Si el silencio dura de verdad, actual() deja de dar tono solo.
        guard var m else {
            if let u = ultimo, Date().timeIntervalSince(u.cuando) > 0.18 { historial.removeAll() }
            return
        }
        // salto de ~12 semitonos de una lectura a otra: casi siempre es un error de octava
        if let prev = historial.last, abs(abs(m - prev) - 12) < 1.0 { m += prev > m ? 12 : -12 }
        historial.append(m)
        if historial.count > 5 { historial.removeFirst() }   // mediana de ~50 ms: suaviza la vibración del trino
        ultimo = (historial.sorted()[historial.count / 2], Date())
    }

    private func ultimoTono() -> Double? {
        lock.lock(); defer { lock.unlock() }
        return ultimo.flatMap { Date().timeIntervalSince($0.cuando) < 0.18 ? $0.midi : nil }
    }

    // MARK: YIN

    private func procesarYIN(_ nuevos: [Float], sr: Double) {
        ventana.append(contentsOf: nuevos)
        if ventana.count > 4096 { ventana.removeFirst(ventana.count - 4096) }
        let f = DetectorTono.yin(ventana, sr: sr)
        publicar(f > 0 ? 69 + 12 * log2(f / 440) : nil)
    }

    // MARK: CREPE (red neuronal, Core ML)

    /// Compila el modelo la primera vez y lo guarda en la caché; las siguientes veces carga al instante.
    static func cargarCrepe() -> MLModel? {
        guard let paquete = Bundle.main.url(forResource: "CrepeFull", withExtension: "mlpackage") else { return nil }
        let version = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.brayan.afinador", isDirectory: true)
        let compilado = cache.appendingPathComponent("CrepeFull-\(version).mlmodelc")
        if !FileManager.default.fileExists(atPath: compilado.path) {
            guard let temporal = try? MLModel.compileModel(at: paquete) else { return nil }
            try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: compilado)
            try? FileManager.default.moveItem(at: temporal, to: compilado)
        }
        let conf = MLModelConfiguration()
        conf.computeUnits = .all   // usa el Neural Engine si está disponible
        return try? MLModel(contentsOf: compilado, configuration: conf)
    }

    private func a16kHz(_ buf: AVAudioPCMBuffer, sr: Double) -> [Float]? {
        guard let conversor else { return nil }
        let cap = AVAudioFrameCount(Double(buf.frameLength) * 16000 / sr) + 32
        guard let salida = AVAudioPCMBuffer(pcmFormat: formato16, frameCapacity: cap) else { return nil }
        var entregado = false
        conversor.convert(to: salida, error: nil) { _, estado in
            if entregado { estado.pointee = .noDataNow; return nil }
            entregado = true; estado.pointee = .haveData; return buf
        }
        guard let ch = salida.floatChannelData?[0], salida.frameLength > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: ch, count: Int(salida.frameLength)))
    }

    /// Cada 10 ms (160 muestras) se analiza una ventana de 1024 muestras; se agrupan en un solo lote.
    private func procesarCREPE(_ nuevos: [Float]) {
        guard let modelo else { return }
        ventana16.append(contentsOf: nuevos)
        pendientes += nuevos.count
        let n = pendientes / 160, resto = pendientes % 160
        pendientes = resto
        defer { if ventana16.count > 4096 { ventana16.removeFirst(ventana16.count - 4096) } }
        guard n > 0, ventana16.count >= 1024 else { return }
        let finales = (0..<n).map { ventana16.count - resto - (n - 1 - $0) * 160 }.filter { $0 >= 1024 }
        guard !finales.isEmpty, let entrada = try? MLMultiArray(shape: [NSNumber(value: finales.count), 1024], dataType: .float32) else { return }
        var sonoro = [Bool](repeating: false, count: finales.count)
        entrada.withUnsafeMutableBufferPointer(ofType: Float.self) { ptr, strides in
            for (k, fin) in finales.enumerated() {
                let marco = Array(ventana16[(fin - 1024)..<fin])
                var norm = [Float](repeating: 0, count: 1024)
                var media: Float = 0, sd: Float = 0
                vDSP_normalize(marco, 1, &norm, 1, &media, &sd, vDSP_Length(1024))   // CREPE espera media 0 y desviación 1
                sonoro[k] = sd > 0.004
                for i in 0..<1024 { ptr[k * strides[0] + i] = sd > 1e-6 ? norm[i] : 0 }
            }
        }
        let inicio = CFAbsoluteTimeGetCurrent()
        guard let resultado = try? modelo.prediction(from: MLDictionaryFeatureProvider(dictionary: ["audio": entrada])),
              let act = resultado.featureValue(for: "activacion")?.multiArrayValue else { return }
        let ms = (CFAbsoluteTimeGetCurrent() - inicio) * 1000 / Double(finales.count)
        msPorAnalisis = msPorAnalisis == 0 ? ms : msPorAnalisis * 0.95 + ms * 0.05
        act.withUnsafeBufferPointer(ofType: Float.self) { ptr in
            let st = act.strides.map { $0.intValue }
            for k in 0..<finales.count {
                let fila = Array(UnsafeBufferPointer(start: ptr.baseAddress! + k * st[0], count: 360))
                let i = fila.indices.max { fila[$0] < fila[$1] }!
                // confianza baja o silencio: no hay voz
                // confianza: 0.5 para empezar una nota; si sigue cerca de lo que venías cantando basta 0.25
                // (en los trinos la red duda más, pero el tono sigue ahí)
                let tonoDelPico = 69 + 12 * log2(10.0 / 440) + (1997.3794 + 20 * Double(i)) / 100   // bin -> semitonos MIDI
                let cercaDelPrevio = ultimoTono().map { abs($0 - tonoDelPico) < 1.5 } ?? false
                guard sonoro[k], fila[i] >= (cercaDelPrevio ? 0.25 : 0.5) else { publicar(nil); continue }
                // media ponderada alrededor del pico: precisión de pocos cents (cada bin son 20 cents)
                var suma: Float = 0, peso: Float = 0
                for b in max(0, i - 4)...min(359, i + 4) { suma += fila[b] * (1997.3794 + 20 * Float(b)); peso += fila[b] }
                let hz = 10 * pow(2, Double(suma / peso) / 1200)
                publicar(69 + 12 * log2(hz / 440))
            }
        }
    }

    static func yin(_ x: [Float], sr: Double) -> Double {
        let n = x.count, w = n / 2
        var rms: Float = 0
        vDSP_rmsqv(x, 1, &rms, vDSP_Length(n))
        if rms < 0.01 { return 0 }
        let tMin = Int(sr / 1000), tMax = min(Int(sr / 65), w - 2)
        var d = [Float](repeating: 0, count: tMax + 2)
        x.withUnsafeBufferPointer { p in
            for tau in 1...(tMax + 1) {
                var s: Float = 0
                vDSP_distancesq(p.baseAddress!, 1, p.baseAddress! + tau, 1, &s, vDSP_Length(w))
                d[tau] = s
            }
        }
        var acum: Float = 0
        d[0] = 1
        for tau in 1...(tMax + 1) { acum += d[tau]; d[tau] = d[tau] * Float(tau) / (acum == 0 ? 1 : acum) }
        var tau = tMin
        while tau <= tMax {
            if d[tau] < 0.15 {
                while tau + 1 <= tMax && d[tau + 1] < d[tau] { tau += 1 }
                let a = d[tau - 1], b = d[tau], c = d[tau + 1]
                let den = 2 * (a - 2 * b + c)
                let shift = den == 0 ? 0 : (a - c) / den
                return sr / (Double(tau) + Double(shift))
            }
            tau += 1
        }
        return 0
    }
}

// MARK: - Estado de la práctica

struct Punto { let t: Double; let m: Double; let ok: Bool? }

/// Cómo cantaste una nota del piano (sin contar el ataque, ya compensado tu retraso).
struct NotaResultado {
    let x: Int, m: Int
    let desvio: Double     // cents: mediana (negativo = bajo)
    let temblor: Double    // cents: cuánto se movió alrededor de la mediana
    let llegada: Double?   // segundos hasta entrar en el margen
    let ok: Bool
}

struct ResumenEjercicio {
    let nombre: String, notas: Int, pct: Int
    let desvio: Double, temblor: Double, llegada: Double?
    let graves: Double?, agudos: Double?
    var consejos: [String] {
        var c: [String] = []
        if abs(desvio) >= 10 { c.append(desvio < 0 ? L("Tiendes a cantar bajo (\(Int(desvio)) cents)") : L("Tiendes a cantar alto (+\(Int(desvio)) cents)")) }
        if let g = graves, let a = agudos, abs(a - g) >= 15 {
            c.append(a < g ? L("En las notas agudas te quedas más bajo") : L("En las notas agudas te pasas hacia arriba"))
        }
        if temblor >= 30 { c.append(L("La nota tiembla: intenta sostenerla más firme")) }
        if let l = llegada, l >= 0.25 { c.append(L("Tardas en llegar a la nota (\(Int(l * 1000)) ms)")) }
        return c.isEmpty ? [L("¡Bien centrado y estable!")] : c
    }
}

/// Cada rutina es una carpeta dentro de Resources con su audio.m4a y su notas.json.
struct Rutina: Identifiable, Hashable { let id: String; let nombre: String }
let RUTINAS = [Rutina(id: "basico", nombre: L("Básico")), Rutina(id: "intermedio", nombre: L("Intermedio"))]

final class Practica: ObservableObject {
    @Published private(set) var datos = Datos(ejercicios: [], notas: [])
    @Published var rutina: Rutina = RUTINAS.first { $0.id == UserDefaults.standard.string(forKey: "rutina") } ?? RUTINAS[0] {
        didSet { UserDefaults.standard.set(rutina.id, forKey: "rutina"); cargar() }
    }
    let detector = DetectorTono()
    private var player: AVAudioPlayer?
    private var timer: Timer?

    @Published var t: Double = 0
    @Published var sonando = false
    @Published var micActivo = false
    @Published var micError = false
    @Published var objetivo: Nota?
    @Published var cantado: Double?
    @Published var ok: Bool?
    @Published var cents: Double = 0
    @Published var ejercicio = -1
    @Published var resultados: [NotaResultado] = []
    /// Retraso de tu voz respecto al piano (reacción + audífonos), estimado mientras cantas.
    @Published var latencia: Double = 0.08
    @Published var objetivoEval: Nota?
    @Published var resumenAbierto = false
    @Published var modoDetector: ModoDetector = ModoDetector(rawValue: UserDefaults.standard.string(forKey: "detector") ?? "") ?? .crepe {
        didSet { UserDefaults.standard.set(modoDetector.rawValue, forKey: "detector"); detector.modo = modoDetector }
    }
    private var retrasos: [Double] = []
    private var muestras: [Int: [Double]] = [:]   // índice de nota -> desvíos (cents) después del ataque
    private var llegadas: [Int: Double] = [:]
    private var contactos: Set<Int> = []
    private var siguienteAEvaluar = 0
    var afinacion: Double { datos.afinacion ?? 0 }
    @Published var trazo: [Punto] = []
    var centro: Double = 50   // tono en el centro de la gráfica; solo se mueve lo justo para que las notas no se salgan
    private var centroIniciado = false
    @Published var ignorarOctava = true
    @Published var menuRutinasAbierto = false
    @Published var margen: Double = 50
    @Published var volumen: Float = 1 { didSet { player?.volume = volumen } }
    @Published var escala: Double = UserDefaults.standard.object(forKey: "escala") as? Double ?? 1.35 {
        didSet { UserDefaults.standard.set(escala, forKey: "escala") }
    }
    /// Zoom del piano roll (⌘ + scroll): >1 acerca (menos segundos y semitonos en pantalla)
    @Published var zoomRoll: Double = UserDefaults.standard.object(forKey: "zoomRoll") as? Double ?? 1 {
        didSet { UserDefaults.standard.set(zoomRoll, forKey: "zoomRoll") }
    }
    func zoomRoll(scroll ev: NSEvent) {
        let dy = ev.hasPreciseScrollingDeltas ? ev.scrollingDeltaY * 0.01 : ev.scrollingDeltaY * 0.1
        zoomRoll = min(4, max(0.4, zoomRoll * exp(dy)))
    }
    func zoom(_ d: Double) { escala = min(3.6, max(0.8, (escala + d) * 100).rounded() / 100) }
    var duracion: Double { player?.duration ?? 600 }

    init() {
        detector.modo = modoDetector
        cargar()
        timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    /// Carga el audio y las notas de la rutina elegida y deja todo en cero.
    private func cargar() {
        player?.stop()
        let carpeta = rutina.id
        if let url = Bundle.main.url(forResource: "notas", withExtension: "json", subdirectory: carpeta),
           let d = try? JSONDecoder().decode(Datos.self, from: Data(contentsOf: url)) { datos = d }
        resultados.removeAll()
        player = Bundle.main.url(forResource: "audio", withExtension: "m4a", subdirectory: carpeta).flatMap { try? AVAudioPlayer(contentsOf: $0) }
        player?.volume = volumen
        player?.prepareToPlay()
        sonando = false
        trazo.removeAll()
        centroIniciado = false
        t = 0
        reiniciarEvaluacion()
    }

    /// Al saltar en el audio se descartan las notas a medio cantar.
    private func reiniciarEvaluacion() {
        muestras.removeAll(); llegadas.removeAll(); contactos.removeAll()
        siguienteAEvaluar = datos.notas.firstIndex { $0.e >= t - latencia } ?? datos.notas.count
    }

    func apagarMic() {
        detector.detener()
        micActivo = false
    }

    func activarMic() {
        detector.arrancar { ok in self.micActivo = ok; self.micError = !ok }
    }

    func pausar() { player?.pause(); sonando = false }

    func playPausa() {
        guard let p = player else { return }
        if p.isPlaying { p.pause() } else { p.play() }
        sonando = p.isPlaying
    }

    func ir(a seg: Double) {
        player?.currentTime = max(0, min(seg, duracion - 0.1))
        trazo.removeAll()
        t = player?.currentTime ?? 0
        reiniciarEvaluacion()
    }

    func irAEjercicio(_ i: Int) {
        ir(a: datos.ejercicios[i].s)
        if !(player?.isPlaying ?? false) { playPausa() }
    }

    func reiniciarPuntajes() {
        resultados.removeAll()
        reiniciarEvaluacion()
    }

    /// Porcentaje de notas afinadas del ejercicio (cada nota cuenta igual, sea larga o corta).
    func porcentaje(_ i: Int) -> Int? {
        let r = resultados.filter { $0.x == i }
        return r.count >= 3 ? Int((100 * Double(r.filter(\.ok).count) / Double(r.count)).rounded()) : nil
    }

    func resumen() -> [ResumenEjercicio] {
        datos.ejercicios.indices.compactMap { i in
            let r = resultados.filter { $0.x == i }
            guard r.count >= 3, let pct = porcentaje(i) else { return nil }
            func media(_ v: [Double]) -> Double { v.reduce(0, +) / Double(max(1, v.count)) }
            let medio = r.map(\.m).sorted()[r.count / 2]
            let g = r.filter { $0.m < medio }.map(\.desvio), a = r.filter { $0.m > medio }.map(\.desvio)
            let ll = r.compactMap(\.llegada)
            return ResumenEjercicio(nombre: "\(i + 1). \(traducir(datos.ejercicios[i].name))", notas: r.count, pct: pct,
                                    desvio: media(r.map(\.desvio)), temblor: media(r.map(\.temblor)),
                                    llegada: ll.isEmpty ? nil : media(ll),
                                    graves: g.count >= 3 ? media(g) : nil, agudos: a.count >= 3 ? media(a) : nil)
        }
    }

    /// Desvío en cents de lo cantado respecto a la nota, contra el piano real (su afinación medida).
    private func desvio(_ s: Double, _ n: Nota) -> Double {
        let meta = Double(n.m) + afinacion / 100
        var j = s
        if ignorarOctava { j -= 12 * ((s - meta) / 12).rounded() }
        return (j - meta) * 100
    }

    /// El ataque (los primeros ms en que la voz se acomoda) no cuenta.
    private func ataque(_ n: Nota) -> Double { min(0.15, (n.e - n.t) * 0.35) }

    private func indiceEn(_ t: Double) -> Int? {
        var lo = 0, hi = datos.notas.count - 1, k = -1
        while lo <= hi {
            let m = (lo + hi) / 2
            if datos.notas[m].t <= t { k = m; lo = m + 1 } else { hi = m - 1 }
        }
        return k >= 0 && t < datos.notas[k].e ? k : nil
    }

    /// Cierra las notas que ya terminaron (con tu retraso) y guarda cómo salieron.
    private func cerrarNotas(hasta tEval: Double) {
        while siguienteAEvaluar < datos.notas.count && datos.notas[siguienteAEvaluar].e < tEval {
            let i = siguienteAEvaluar, n = datos.notas[i]
            if let v = muestras[i], v.count >= 3 {
                let orden = v.sorted(), med = orden[orden.count / 2]
                let temblor = (v.map { ($0 - med) * ($0 - med) }.reduce(0, +) / Double(v.count)).squareRoot()
                resultados.append(NotaResultado(x: n.x, m: n.m, desvio: med, temblor: temblor, llegada: llegadas[i], ok: abs(med) <= margen))
            }
            muestras[i] = nil; llegadas[i] = nil
            siguienteAEvaluar += 1
        }
    }

    private func notaEn(_ t: Double) -> Nota? {
        var lo = 0, hi = datos.notas.count - 1, k = -1
        while lo <= hi {
            let m = (lo + hi) / 2
            if datos.notas[m].t <= t { k = m; lo = m + 1 } else { hi = m - 1 }
        }
        return k >= 0 && t < datos.notas[k].e ? datos.notas[k] : nil
    }

    /// La vista vertical no persigue cada nota: se queda quieta mientras las notas cercanas quepan,
    /// y si alguna se va a salir, se desliza suave solo lo necesario para mostrarla.
    private func seguirNotas() {
        let rango = 16 / zoomRoll, ventana = 4.5 / zoomRoll
        let mitad = rango / 2 - min(2.5, rango * 0.2)   // deja un margen arriba y abajo (fuera del difuminado)
        let cerca = datos.notas.filter { $0.e >= t - ventana * 0.3 && $0.t <= t + ventana * 0.8 }
        guard let lo = cerca.map({ Double($0.m) }).min(), let hi = cerca.map({ Double($0.m) }).max() else { return }
        var deseado = centro
        if hi - lo <= 2 * mitad {
            if hi > deseado + mitad { deseado = hi - mitad }
            if lo < deseado - mitad { deseado = lo + mitad }
        } else {
            // mucho zoom: no caben todas, así que se asegura la que suena y la siguiente (si las dos caben)
            let siguientes = cerca.filter { $0.t > t }.prefix(1)
            var foco = (objetivo.map { [$0] } ?? []) + siguientes
            if foco.count == 2, abs(Double(foco[0].m - foco[1].m)) > 2 * mitad { foco = [foco[0]] }
            if let fHi = foco.map({ Double($0.m) }).max(), let fLo = foco.map({ Double($0.m) }).min() {
                if fHi > deseado + mitad { deseado = fHi - mitad }
                if fLo < deseado - mitad { deseado = fLo + mitad }
            }
        }
        if !centroIniciado { centro = (lo + hi) / 2; centroIniciado = true; return }
        centro += (deseado - centro) * 0.06
    }

    private func tick() {
        guard let p = player else { return }
        // Sin audio sonando ni micrófono no cambia nada. Antes se publicaba igual 60 veces por segundo y, como todas las
        // pantallas observan Practica, la app entera se redibujaba sin parar (por eso iba lenta hasta en las materias).
        guard p.isPlaying || sonando || micActivo else {
            if cantado != nil { cantado = nil; ok = nil }   // al apagar el micrófono no queda la última nota pegada
            return
        }
        t = p.currentTime
        if sonando != p.isPlaying { sonando = p.isPlaying }
        objetivo = notaEn(t)
        ejercicio = datos.ejercicios.firstIndex { t >= $0.s && t < $0.e } ?? -1
        seguirNotas()
        cantado = detector.actual()
        ok = nil
        let tEval = t - latencia
        let idx = indiceEn(tEval)
        objetivoEval = idx.map { datos.notas[$0] }
        if sonando { cerrarNotas(hasta: tEval) }
        guard let s = cantado else { return }
        if sonando {
            // retraso: cuánto tardas en acercarte (a menos de un semitono) a cada nota nueva
            var k = indiceEn(t) ?? -1
            while k >= 0 && datos.notas[k].t > t - 0.5 {
                if !contactos.contains(k) && abs(desvio(s, datos.notas[k])) < 100 {
                    contactos.insert(k)
                    retrasos.append(t - datos.notas[k].t)
                    if retrasos.count > 40 { retrasos.removeFirst() }
                    if retrasos.count >= 8 { latencia = min(0.3, max(0, retrasos.sorted()[retrasos.count / 2])) }
                }
                k -= 1
            }
        }
        if let i = idx {
            let n = datos.notas[i], d = desvio(s, n)
            cents = d
            if tEval - n.t >= ataque(n) {
                ok = abs(d) <= margen
                if sonando { muestras[i, default: []].append(d) }
            }
            if sonando && llegadas[i] == nil && abs(d) <= margen { llegadas[i] = max(0, tEval - n.t) }
        }
        if sonando {
            trazo.append(Punto(t: t, m: s, ok: ok))
            if let f = trazo.first, f.t < t - 7 { trazo.removeFirst(trazo.prefix { $0.t < t - 7 }.count) }
        }
    }

    var nombreCantado: String {
        guard let s = cantado else { return "–" }
        let r = Int(s.rounded())
        if let o = objetivo, ((r - o.m) % 12 + 12) % 12 == 0 { return nota(o.n) }
        return nota(SOLF[((r % 12) + 12) % 12])
    }

    var consejo: String {
        if !micActivo { return L("Activa el micrófono para empezar") }
        guard let o = objetivoEval else { return sonando ? L("Espera la siguiente nota") : L("Dale play y canta con el piano") }
        guard cantado != nil, let ok else { return L("Canta: \(nota(o.n))") }
        if ok { return L("¡Afinado!") }
        if cents < 0 { return cents < -150 ? L("Sube bastante ↑") : L("Sube un poco ↑") }
        return cents > 150 ? L("Baja bastante ↓") : L("Baja un poco ↓")
    }
}

// MARK: - Gráfica de tono

/// Capa transparente sobre el piano roll que recibe la rueda del ratón: con ⌘ hace zoom.
struct CapturaScroll: NSViewRepresentable {
    let alHacerZoom: (NSEvent) -> Void
    final class Vista: NSView {
        var alHacerZoom: ((NSEvent) -> Void)?
        override func scrollWheel(with ev: NSEvent) {
            let cmd = ev.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.command)
            if cmd { alHacerZoom?(ev) } else { super.scrollWheel(with: ev) }
        }
        // pellizco con dos dedos en el trackpad
        override func magnify(with ev: NSEvent) { alPellizcar?(ev.magnification) }
        var alPellizcar: ((Double) -> Void)?
    }
    let alPellizcar: (Double) -> Void
    func makeNSView(context: Context) -> Vista { let v = Vista(); updateNSView(v, context: context); return v }
    func updateNSView(_ v: Vista, context: Context) { v.alHacerZoom = alHacerZoom; v.alPellizcar = alPellizcar }
}

struct Grafica: View {
    @ObservedObject var p: Practica

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height, pasado = 4.5 / p.zoomRoll, futuro = 4.5 / p.zoomRoll, rango = 16.0 / p.zoomRoll, e = p.escala
            let t = p.t
            let c = p.centro
            func X(_ tt: Double) -> Double { (tt - (t - pasado)) / (pasado + futuro) * w }
            func Y(_ m: Double) -> Double { h / 2 - (m - c) / rango * h }

            var rotulos: [(Int, CGFloat)] = []
            for m in Int(floor(c - rango / 2))...Int(ceil(c + rango / 2)) {
                let y = Y(Double(m)), nat = NATURALES.contains(((m % 12) + 12) % 12)
                // al alejar mucho solo se rotulan los DO para que no se encimen
                let rotular = (h / rango) * 1.5 >= 13 * e ? nat : ((m % 12) + 12) % 12 == 0
                if rotular { rotulos.append((m, y)) }
                let grueso: CGFloat = nat ? 1 : 0.5
                ctx.fill(Path(CGRect(x: 0, y: y - grueso / 2, width: w, height: grueso)), with: .color(.white.opacity(nat ? 0.12 : 0.06)))
            }
            ctx.fill(Path(CGRect(x: X(t), y: 0, width: 2, height: h)), with: .color(.white.opacity(0.35)))

            // grosor de la barra: el pedido, pero nunca más que el alto de un semitono
            let semitono = h / rango
            let alto = min(28 * e, max(8, semitono * 0.95))
            let fuente = min(14 * e, max(10, alto * 0.62))
            // primero se mide todo; los nombres van todos dentro o todos encima, nunca mezclados
            let visibles = p.datos.notas.filter { $0.e >= t - pasado && $0.t <= t + futuro }
            let barras = visibles.map { n -> (Nota, CGRect, CGFloat) in
                let r = CGRect(x: X(n.t), y: Y(Double(n.m)) - alto / 2, width: max(4, X(n.e) - X(n.t) - 3), height: alto)
                let ancho = ctx.resolve(Text(nota(n.n)).font(.system(size: fuente, weight: .bold))).measure(in: CGSize(width: 400, height: 100)).width
                return (n, r, ancho)
            }
            let todasDentro = barras.allSatisfy { $0.2 + 16 * e <= $0.1.width }
            let todasEncima = barras.allSatisfy { $0.2 <= ($0.1.width + 3) * 1.8 }
            for (n, r, _) in barras {
                let activa = t >= n.t && t < n.e
                ctx.fill(Path(roundedRect: r, cornerRadius: min(alto, r.width) / 2), with: .color(Color.crema.opacity(activa ? 1 : 0.5)))
                if todasDentro {
                    ctx.draw(Text(nota(n.n)).font(.system(size: fuente, weight: .bold)).foregroundStyle(Color.fondo),
                             at: CGPoint(x: r.minX + 8 * e, y: r.midY), anchor: .leading)
                } else if todasEncima {
                    ctx.draw(Text(nota(n.n)).font(.system(size: fuente, weight: .bold)).foregroundStyle(Color.crema.opacity(activa ? 1 : 0.75)),
                             at: CGPoint(x: r.midX, y: r.minY - 3), anchor: .bottom)
                }
            }

            let tr = p.trazo
            if tr.count > 1 {
                for i in 1..<tr.count {
                    let a = tr[i - 1], b = tr[i]
                    if b.t - a.t > 0.15 || b.t < a.t { continue }
                    var seg = Path()
                    seg.move(to: CGPoint(x: X(a.t), y: Y(a.m)))
                    seg.addLine(to: CGPoint(x: X(b.t), y: Y(b.m)))
                    let col: Color = b.ok == nil ? .suave : (b.ok! ? .afinado : .desafinado)
                    ctx.stroke(seg, with: .color(col), style: StrokeStyle(lineWidth: 4 * e, lineCap: .round))
                }
            }

            // rótulos de la izquierda encima de todo, sobre una franja del color de fondo, centrados en su línea
            let franja = 16 + 46 * e
            ctx.fill(Path(CGRect(x: 0, y: 0, width: franja, height: h)),
                     with: .linearGradient(Gradient(colors: [Color.fondo.opacity(0.45), Color.fondo.opacity(0)]),
                                           startPoint: CGPoint(x: franja * 0.6, y: 0), endPoint: CGPoint(x: franja, y: 0)))
            for (m, y) in rotulos {
                ctx.draw(Text(verbatim: "\(nota(SOLF[m % 12]))\(m / 12 - 1)").font(.system(size: 12 * e, weight: .medium)).foregroundStyle(Color.suave.opacity(0.85)),
                         at: CGPoint(x: 16, y: y), anchor: .leading)
            }
        }
    }
}

// MARK: - Interfaz

/// Desenfoque de lo que hay detrás de la ventana (el escritorio y otras ventanas).
struct VidrioVentana: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

struct Contenido: View {
    @ObservedObject var p: Practica
    var derecha: AnyView? = nil   // botones extra al final de la fila de arriba (inicio y clase)
    private func z(_ v: CGFloat) -> CGFloat { v * p.escala }

    var body: some View {
        ZStack {
            // el fondo (vidrio + tinte oscuro) lo pone la ventana
            Grafica(p: p)
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.07),
                                             .init(color: .black, location: 0.93), .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(CapturaScroll(alHacerZoom: { p.zoomRoll(scroll: $0) }, alPellizcar: { p.zoomRoll = min(4, max(0.4, p.zoomRoll * (1 + $0))) })).padding(.top, z(80)).padding(.bottom, z(130))

            VStack(spacing: 0) {
                // con zoom grande la fila no cabe: el selector y los botones de la derecha se quedan fijos
                // y los ejercicios se desplazan de lado (antes todo crecía por fuera de la ventana)
                HStack(spacing: z(12)) {
                    selectorRutina
                    Spacer(minLength: 0)
                    ViewThatFits(in: .horizontal) {
                        chips
                        ScrollView(.horizontal, showsIndicators: false) { chips.padding(.vertical, 2) }
                    }
                    Spacer(minLength: 0)
                    if let derecha { derecha }
                }
                .padding(.top, z(30))
                Spacer()
                lectura
                barra.padding(.bottom, z(16)).padding(.top, z(10))
            }
            .padding(.horizontal, z(16))

            if p.resumenAbierto {
                Color.black.opacity(0.25).ignoresSafeArea().onTapGesture { p.resumenAbierto = false }
                panelResumen.transition(.opacity.combined(with: .scale(scale: 0.97)))
            }

            if p.menuRutinasAbierto {
                Color.black.opacity(0.001).ignoresSafeArea().onTapGesture { p.menuRutinasAbierto = false }
                listaRutinas
                    .padding(.top, z(30) + z(36) + z(8)).padding(.leading, z(16))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .topLeading)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: p.menuRutinasAbierto)
        .animation(.easeOut(duration: 0.18), value: p.resumenAbierto)
        // el mínimo no crece con el zoom: si no, la vista quedaba más ancha que la ventana y se salía por los lados
        .frame(minWidth: 760, minHeight: 480)
        .preferredColorScheme(.dark)
    }

    // desplegable propio (no el menú del sistema) para que crezca con la interfaz
    private var selectorRutina: some View {
        Button { p.menuRutinasAbierto.toggle() } label: {
            HStack(spacing: z(8)) {
                Image(systemName: "music.note.list")
                Text(p.rutina.nombre).fontWeight(.semibold)
                Image(systemName: p.menuRutinasAbierto ? "chevron.up" : "chevron.down")
                    .font(.system(size: z(10), weight: .bold)).foregroundStyle(.secondary)
            }
            .font(.system(size: z(14)))
            .padding(.horizontal, z(16)).frame(height: z(36))
            .contentShape(Capsule())
        }
        .buttonStyle(.hoverCapsula)
        .fixedSize()
        .glassEffect(.regular, in: .capsule)
        .help("Elegir rutina de calentamiento")
    }

    private var listaRutinas: some View {
        VStack(alignment: .leading, spacing: z(2)) {
            ForEach(RUTINAS) { r in
                Button {
                    p.menuRutinasAbierto = false
                    if r != p.rutina { p.rutina = r }
                } label: {
                    HStack(spacing: z(10)) {
                        Image(systemName: "checkmark").opacity(r == p.rutina ? 1 : 0)
                        Text(r.nombre)
                        Spacer(minLength: z(24))
                    }
                    .font(.system(size: z(14), weight: r == p.rutina ? .semibold : .regular))
                    .padding(.horizontal, z(14)).frame(height: z(34))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.hover)
            }
        }
        .padding(z(6))
        .fixedSize()
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: z(16)))
    }

    private var chips: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                ForEach(Array(p.datos.ejercicios.enumerated()), id: \.offset) { i, ex in
                    Button { p.irAEjercicio(i) } label: {
                        HStack(spacing: 8) {
                            Text(verbatim: "\(i + 1). \(traducir(ex.name))")
                            if let pc = p.porcentaje(i) {
                                Text("\(pc)% afinado").foregroundStyle(Color.crema).fontWeight(.bold).monospacedDigit()
                            }
                        }
                        .font(.system(size: z(13), weight: .medium))
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, z(14)).padding(.vertical, z(8))
                    }
                    .buttonStyle(.hoverCapsula)
                    .glassEffect(i == p.ejercicio ? .regular.tint(Color.crema.opacity(0.35)) : .regular, in: .capsule)
                }
            }
        }
    }

    /// PIANO · TÚ · consejo en una fila; con zoom grande el consejo baja debajo de las notas para no salirse de la ventana.
    private var lectura: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: z(28)) { notas; consejo.frame(minWidth: z(240), alignment: .leading) }
                .padding(.horizontal, z(24)).padding(.vertical, z(12))
                .glassEffect(.regular, in: .capsule)
            VStack(spacing: z(6)) { notas; consejo.multilineTextAlignment(.center) }
                .padding(.horizontal, z(24)).padding(.vertical, z(12))
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: z(24)))
        }
    }

    private var notas: some View {
        HStack(spacing: z(28)) {
            etiqueta("PIANO", p.objetivo.map { nota($0.n) } ?? "–", .crema)
            etiqueta("TÚ", p.nombreCantado, p.ok == nil ? .white : (p.ok! ? .afinado : .desafinado))
        }
    }

    private var consejo: some View {
        Text(p.consejo).font(.system(size: z(20), weight: .semibold, design: .rounded)).fixedSize(horizontal: false, vertical: true)
    }

    private func etiqueta(_ titulo: String, _ valor: String, _ color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(traducir(titulo)).font(.system(size: z(11), weight: .semibold)).kerning(1.2).foregroundStyle(.secondary)
            Text(valor).font(.system(size: z(30), weight: .bold, design: .rounded)).foregroundStyle(color).frame(minWidth: z(80), alignment: .leading)
        }
    }

    /// En una fila si cabe; si no (zoom grande), los controles bajan a una segunda fila, y si aun así no caben, se desplazan.
    private var barra: some View {
        GlassEffectContainer(spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { reproduccion; controles }
                VStack(spacing: z(10)) {
                    reproduccion
                    ViewThatFits(in: .horizontal) {
                        controles
                        ScrollView(.horizontal, showsIndicators: false) { controles }
                    }
                }
            }
        }
    }

    private var reproduccion: some View {
        HStack(spacing: 14) {
                Button(action: p.playPausa) {
                    Image(systemName: p.sonando ? "pause.fill" : "play.fill").font(.system(size: z(18), weight: .semibold)).frame(width: z(44), height: z(44))
                }
                .buttonStyle(.glass).buttonBorderShape(.circle).keyboardShortcut(.space, modifiers: [])

                HStack(spacing: 12) {
                    Text(reloj(p.t)).monospacedDigit().foregroundStyle(.secondary)
                    Slider(value: Binding(get: { p.t }, set: { p.ir(a: $0) }), in: 0...p.duracion)
                    Text(reloj(p.duracion)).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.system(size: z(13)))
                .padding(.horizontal, z(16)).frame(minWidth: z(260)).frame(height: z(44))
                .glassEffect(.regular, in: .capsule)
        }
    }

    private var controles: some View {
                HStack(spacing: z(14)) {
                    if p.micActivo {
                        Label("Micrófono", systemImage: "mic.fill").foregroundStyle(Color.afinado)
                    } else {
                        Button { p.activarMic() } label: { Label(p.micError ? "Permitir micrófono" : "Activar micrófono", systemImage: "mic").padding(.horizontal, z(10)).frame(height: z(32)).contentShape(Capsule()) }
                            .buttonStyle(.hoverCapsula)
                    }
                    Picker("", selection: $p.modoDetector) {
                        ForEach(ModoDetector.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().frame(width: z(84)).help("Detector de tono: CREPE (red neuronal) o YIN (clásico)")
                    Toggle("Ignorar octava", isOn: $p.ignorarOctava).toggleStyle(.switch).controlSize(.mini)
                    Picker("", selection: $p.margen) {
                        Text("±50 cents").tag(50.0)
                        Text("±25 cents").tag(25.0)
                    }
                    .labelsHidden().frame(width: z(104))
                    Image(systemName: "speaker.wave.2.fill").foregroundStyle(.secondary)
                    Slider(value: $p.volumen, in: 0...1).frame(width: z(80))
                    Button { p.resumenAbierto.toggle() } label: { Image(systemName: "chart.bar.xaxis") }
                        .buttonStyle(.icono(z(30))).help("Ver resumen de cómo vas")
                    Button { p.reiniciarPuntajes() } label: { Image(systemName: "arrow.counterclockwise") }
                        .buttonStyle(.icono(z(30))).help("Reiniciar porcentajes")
                }
                .font(.system(size: z(13)))
                .fixedSize()
                .padding(.horizontal, z(16)).frame(height: z(44))
                .glassEffect(.regular, in: .capsule)
    }

    private var panelResumen: some View {
        let filas = p.resumen()
        let ms = p.detector.msPorAnalisis
        return VStack(alignment: .leading, spacing: z(14)) {
            HStack {
                Text("Resumen · \(p.rutina.nombre)").font(.system(size: z(20), weight: .bold, design: .rounded))
                Spacer()
                Button { p.resumenAbierto = false } label: { Image(systemName: "xmark").font(.system(size: z(13), weight: .bold)) }
                    .buttonStyle(.icono(z(30)))
            }
            HStack(spacing: z(18)) {
                dato("Piano", String(format: "%+.1f cents", p.afinacion))
                dato("Tu retraso", "\(Int(p.latencia * 1000)) ms")
                dato("Detector", p.modoDetector == .crepe ? (ms > 0 ? String(format: "CREPE · %.1f ms", ms) : "CREPE") : "YIN")
            }
            Divider().opacity(0.4)
            if filas.isEmpty {
                Text("Canta un ejercicio con el micrófono activo y aquí verás cómo te fue en cada uno.")
                    .font(.system(size: z(14))).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: z(14)) {
                        ForEach(filas, id: \.nombre) { f in
                            VStack(alignment: .leading, spacing: z(6)) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(f.nombre).font(.system(size: z(15), weight: .semibold))
                                    Spacer()
                                    Text("\(f.pct)% afinado").font(.system(size: z(15), weight: .bold)).monospacedDigit()
                                        .foregroundStyle(f.pct >= 70 ? Color.afinado : Color.desafinado)
                                }
                                HStack(spacing: z(18)) {
                                    dato("Notas", "\(f.notas)")
                                    dato("Desvío medio", String(format: "%+.0f cents", f.desvio))
                                    dato("Temblor", String(format: "±%.0f cents", f.temblor))
                                    dato("Llegada", f.llegada.map { "\(Int($0 * 1000)) ms" } ?? "–")
                                    if let g = f.graves, let a = f.agudos {
                                        dato("Graves / agudas", String(format: "%+.0f / %+.0f", g, a))
                                    }
                                }
                                ForEach(f.consejos, id: \.self) { c in
                                    Label(c, systemImage: "lightbulb").font(.system(size: z(13))).foregroundStyle(Color.suave)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: z(380))
            }
        }
        .padding(z(22))
        .frame(width: z(640))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: z(24)))
    }

    private func dato(_ titulo: String, _ valor: String) -> some View {
        VStack(alignment: .leading, spacing: z(2)) {
            Text(traducir(titulo).uppercased()).font(.system(size: z(10), weight: .semibold)).kerning(1).foregroundStyle(.secondary)
            Text(valor).font(.system(size: z(14), weight: .semibold)).monospacedDigit()
        }
    }

    private func reloj(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }
}
