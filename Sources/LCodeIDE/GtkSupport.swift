import CAdw
import Foundation

// Helpers for driving GTK from Swift: pointer casts, signals, main thread.

/// Casts a GTK pointer to another GObject type (like the GTK_* macros).
@inline(__always)
func cast<T>(_ pointer: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<T> {
    pointer!.assumingMemoryBound(to: T.self)
}

@inline(__always)
func raw<T>(_ pointer: UnsafeMutablePointer<T>?) -> UnsafeMutableRawPointer? {
    pointer.map { UnsafeMutableRawPointer($0) }
}

/// For GTK types imported as opaque pointers (incomplete structs).
@inline(__always)
func cast(_ pointer: UnsafeMutableRawPointer?) -> OpaquePointer {
    OpaquePointer(pointer!)
}

@inline(__always)
func raw(_ pointer: OpaquePointer?) -> UnsafeMutableRawPointer? {
    pointer.map { UnsafeMutableRawPointer($0) }
}

/// Swift closure called by a GTK signal (kept alive for the app's lifetime).
final class SignalBox {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
}

private var signalBoxes: [SignalBox] = []

/// Connects a signal without useful arguments (clicked, activate, changed…).
func connect(_ instance: UnsafeMutableRawPointer?, _ signal: String, _ action: @escaping () -> Void) {
    let box = SignalBox(action)
    signalBoxes.append(box)
    let callback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, data in
        Unmanaged<SignalBox>.fromOpaque(data!).takeUnretainedValue().action()
    }
    _ = lcode_connect(instance, signal, unsafeBitCast(callback, to: GCallback.self), Unmanaged.passUnretained(box).toOpaque())
}

/// Connects a signal whose first argument is a pointer (row-activated, notify…).
func connectArg(_ instance: UnsafeMutableRawPointer?, _ signal: String, _ action: @escaping (UnsafeMutableRawPointer?) -> Void) {
    final class ArgBox { let action: (UnsafeMutableRawPointer?) -> Void; init(_ a: @escaping (UnsafeMutableRawPointer?) -> Void) { action = a } }
    let box = ArgBox(action)
    signalBoxes.append(SignalBox { _ = box })
    let callback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, arg, data in
        Unmanaged<ArgBox>.fromOpaque(data!).takeUnretainedValue().action(arg)
    }
    _ = lcode_connect(instance, signal, unsafeBitCast(callback, to: GCallback.self), Unmanaged.passRetained(box).toOpaque())
}

/// Connects a signal that returns a boolean (close-request…); always returns FALSE so default handling runs.
func connectReturningFalse(_ instance: UnsafeMutableRawPointer?, _ signal: String, _ action: @escaping () -> Void) {
    let box = SignalBox(action)
    signalBoxes.append(box)
    let callback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> gboolean = { _, data in
        Unmanaged<SignalBox>.fromOpaque(data!).takeUnretainedValue().action()
        return 0
    }
    _ = lcode_connect(instance, signal, unsafeBitCast(callback, to: GCallback.self), Unmanaged.passUnretained(box).toOpaque())
}

/// Runs a closure on the GTK thread, from any thread.
func onMain(_ action: @escaping () -> Void) {
    let box = Unmanaged.passRetained(SignalBox(action)).toOpaque()
    let callback: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { data in
        let box = Unmanaged<SignalBox>.fromOpaque(data!).takeRetainedValue()
        box.action()
        return 0
    }
    g_idle_add(callback, box)
}

/// Runs a closure once on the GTK thread after a delay in milliseconds.
func after(_ milliseconds: UInt32, _ action: @escaping () -> Void) {
    let box = Unmanaged.passRetained(SignalBox(action)).toOpaque()
    let callback: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { data in
        let box = Unmanaged<SignalBox>.fromOpaque(data!).takeRetainedValue()
        box.action()
        return 0
    }
    g_timeout_add(milliseconds, callback, box)
}

/// Adds a `win.<name>` action triggered by a keyboard shortcut.
func addAction(_ window: UnsafeMutablePointer<GtkWidget>, _ name: String, accel: String, _ action: @escaping () -> Void) {
    let simple = g_simple_action_new(name, nil)
    // "activate" passes (action, parameter, data): a three-argument callback.
    connectArg(raw(simple), "activate") { _ in action() }
    g_action_map_add_action(OpaquePointer(window), simple)
    lcode_shortcut(window, accel, "win." + name)
}
