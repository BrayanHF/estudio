import AVFoundation
import CoreAudio
import AudioToolbox

/// Qué micrófono usa la app. Al conectar audífonos Bluetooth, macOS suele volver su micrófono la entrada por
/// defecto. Si la app lo abre, el Bluetooth pasa a "modo llamada": el sonido de los audífonos se vuelve de teléfono
/// y la entrada cambia a mitad del ejercicio. Por eso nunca se usa un micrófono Bluetooth si hay otro (el fifine USB).
enum Microfono {
    private static func propiedad<T>(_ objeto: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                     _ alcance: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, inicial: T) -> T {
        var dir = AudioObjectPropertyAddress(mSelector: selector, mScope: alcance, mElement: kAudioObjectPropertyElementMain)
        var valor = inicial
        var tam = UInt32(MemoryLayout<T>.size)
        _ = AudioObjectGetPropertyData(objeto, &dir, 0, nil, &tam, &valor)
        return valor
    }

    private static var dispositivos: [AudioDeviceID] {
        var dir = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
        var tam: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &dir, 0, nil, &tam) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(tam) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &dir, 0, nil, &tam, &ids) == noErr else { return [] }
        return ids
    }

    private static func tieneEntrada(_ id: AudioDeviceID) -> Bool {
        var dir = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput,
                                             mElement: kAudioObjectPropertyElementMain)
        var tam: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &dir, 0, nil, &tam) == noErr && tam > 0
    }

    private static func transporte(_ id: AudioDeviceID) -> UInt32 { propiedad(id, kAudioDevicePropertyTransportType, inicial: UInt32(0)) }

    private static func esBluetooth(_ id: AudioDeviceID) -> Bool {
        [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE].contains(transporte(id))
    }

    /// La entrada por defecto, salvo que sea Bluetooth: entonces la primera USB, o cualquiera que no sea Bluetooth.
    static func elegido() -> AudioDeviceID? {
        let defecto: AudioDeviceID = propiedad(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, inicial: 0)
        if defecto != 0, !esBluetooth(defecto) { return defecto }
        let entradas = dispositivos.filter { tieneEntrada($0) && !esBluetooth($0) }
        return entradas.first { transporte($0) == kAudioDeviceTransportTypeUSB } ?? entradas.first ?? (defecto != 0 ? defecto : nil)
    }

    /// Fija el micrófono del motor. Va antes de leer el formato de la entrada y de arrancarlo.
    static func fijar(en engine: AVAudioEngine) {
        guard var id = elegido(), let unidad = engine.inputNode.audioUnit else { return }
        AudioUnitSetProperty(unidad, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                             &id, UInt32(MemoryLayout<AudioDeviceID>.size))
    }
}
