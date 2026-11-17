import CAdw
import Foundation

// Petits outils pour piloter GTK depuis Swift : conversions de pointeurs, signaux, fil principal.

/// Conversion d'un pointeur GTK vers un autre type de la hiérarchie GObject (équivalent des macros GTK_*).
@inline(__always)
func cast<T>(_ pointer: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<T> {
    pointer!.assumingMemoryBound(to: T.self)
}

@inline(__always)
func raw<T>(_ pointer: UnsafeMutablePointer<T>?) -> UnsafeMutableRawPointer? {
    pointer.map { UnsafeMutableRawPointer($0) }
}

/// Types GTK importés comme pointeurs opaques (structures incomplètes).
@inline(__always)
func cast(_ pointer: UnsafeMutableRawPointer?) -> OpaquePointer {
    OpaquePointer(pointer!)
}

@inline(__always)
func raw(_ pointer: OpaquePointer?) -> UnsafeMutableRawPointer? {
    pointer.map { UnsafeMutableRawPointer($0) }
}

/// Fermetures Swift appelées par les signaux GTK (gardées en vie tant que l'application tourne).
final class SignalBox {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
}

private var signalBoxes: [SignalBox] = []

/// Connecte un signal sans argument utile (clicked, activate, changed…).
func connect(_ instance: UnsafeMutableRawPointer?, _ signal: String, _ action: @escaping () -> Void) {
    let box = SignalBox(action)
    signalBoxes.append(box)
    let callback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, data in
        Unmanaged<SignalBox>.fromOpaque(data!).takeUnretainedValue().action()
    }
    _ = lcode_connect(instance, signal, unsafeBitCast(callback, to: GCallback.self), Unmanaged.passUnretained(box).toOpaque())
}

/// Connecte un signal qui transmet un pointeur en premier argument (row-activated, notify…).
func connectArg(_ instance: UnsafeMutableRawPointer?, _ signal: String, _ action: @escaping (UnsafeMutableRawPointer?) -> Void) {
    final class ArgBox { let action: (UnsafeMutableRawPointer?) -> Void; init(_ a: @escaping (UnsafeMutableRawPointer?) -> Void) { action = a } }
    let box = ArgBox(action)
    signalBoxes.append(SignalBox { _ = box })
    let callback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, arg, data in
        Unmanaged<ArgBox>.fromOpaque(data!).takeUnretainedValue().action(arg)
    }
    _ = lcode_connect(instance, signal, unsafeBitCast(callback, to: GCallback.self), Unmanaged.passRetained(box).toOpaque())
}

/// Connecte un signal qui attend un booléen en retour (close-request…) : renvoie toujours FALSE
/// (le traitement par défaut continue).
func connectReturningFalse(_ instance: UnsafeMutableRawPointer?, _ signal: String, _ action: @escaping () -> Void) {
    let box = SignalBox(action)
    signalBoxes.append(box)
    let callback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> gboolean = { _, data in
        Unmanaged<SignalBox>.fromOpaque(data!).takeUnretainedValue().action()
        return 0
    }
    _ = lcode_connect(instance, signal, unsafeBitCast(callback, to: GCallback.self), Unmanaged.passUnretained(box).toOpaque())
}

/// Exécute une fermeture sur le fil de GTK (depuis n'importe quel fil).
func onMain(_ action: @escaping () -> Void) {
    let box = Unmanaged.passRetained(SignalBox(action)).toOpaque()
    let callback: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { data in
        let box = Unmanaged<SignalBox>.fromOpaque(data!).takeRetainedValue()
        box.action()
        return 0
    }
    g_idle_add(callback, box)
}

/// Exécute une fermeture une fois, après un délai (millisecondes), sur le fil de GTK.
func after(_ milliseconds: UInt32, _ action: @escaping () -> Void) {
    let box = Unmanaged.passRetained(SignalBox(action)).toOpaque()
    let callback: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { data in
        let box = Unmanaged<SignalBox>.fromOpaque(data!).takeRetainedValue()
        box.action()
        return 0
    }
    g_timeout_add(milliseconds, callback, box)
}

/// Ajoute à une fenêtre une action « win.<nom> » déclenchée par un raccourci clavier.
func addAction(_ window: UnsafeMutablePointer<GtkWidget>, _ name: String, accel: String, _ action: @escaping () -> Void) {
    let simple = g_simple_action_new(name, nil)
    // « activate » transmet (action, paramètre, données) : rappel à trois arguments.
    connectArg(raw(simple), "activate") { _ in action() }
    g_action_map_add_action(OpaquePointer(window), simple)
    lcode_shortcut(window, accel, "win." + name)
}
