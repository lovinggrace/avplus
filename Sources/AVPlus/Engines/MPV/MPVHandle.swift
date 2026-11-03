import Foundation
import Libmpv

/// Thread-safe owner of an `mpv_handle`.
///
/// libmpv's client API may be called from any thread, but the handle must not be used after
/// `mpv_terminate_destroy`. All access goes through `lock`, and events are drained on a private
/// serial queue and handed out as `Sendable` values.
final class MPVHandle: @unchecked Sendable {
    enum Value: Sendable, Equatable {
        case none
        case flag(Bool)
        case int(Int64)
        case double(Double)
        case string(String)
    }

    enum Event: Sendable {
        case property(name: String, value: Value)
        /// `sub-text` changed; start/end are read at the same moment.
        case subtitle(text: String?, start: Double?, end: Double?)
        case fileLoaded
        case playbackRestart
        case endFile(error: String?)
    }

    private let lock = NSLock()
    private var pointer: OpaquePointer?
    private let queue = DispatchQueue(label: "AVPlus.mpv.events", qos: .userInitiated)
    private let onEvents: @Sendable ([Event]) -> Void

    /// - Parameters:
    ///   - options: Applied in order before `mpv_initialize`.
    ///   - windowID: Pointer to the `CAMetalLayer` mpv renders into, passed as the `wid` option.
    ///   - onEvents: Called on a background queue with batches of events, in order.
    init(options: [(String, String)], windowID: Int64, onEvents: @escaping @Sendable ([Event]) -> Void) throws {
        guard let pointer = mpv_create() else {
            throw PlaybackError("Could not create an mpv instance", backend: .mpv)
        }
        self.onEvents = onEvents

        var wid = windowID
        mpv_set_option(pointer, "wid", MPV_FORMAT_INT64, &wid)
        for (name, value) in options {
            mpv_set_option_string(pointer, name, value)
        }
        let status = mpv_initialize(pointer)
        guard status >= 0 else {
            mpv_terminate_destroy(pointer)
            throw PlaybackError("mpv failed to initialize: \(String(cString: mpv_error_string(status)))", backend: .mpv)
        }
        self.pointer = pointer

        // Balanced in `destroy()`, so the callback context outlives every wakeup.
        let context = Unmanaged.passRetained(self).toOpaque()
        mpv_set_wakeup_callback(pointer, { context in
            guard let context else { return }
            Unmanaged<MPVHandle>.fromOpaque(context).takeUnretainedValue().scheduleDrain()
        }, context)
    }

    // MARK: - Commands and properties

    @discardableResult
    func command(_ arguments: [String]) -> Int32 {
        withPointer { pointer in
            var cStrings: [UnsafePointer<CChar>?] = arguments.map { UnsafePointer(strdup($0)) }
            cStrings.append(nil)
            defer { cStrings.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
            return mpv_command(pointer, &cStrings)
        } ?? MPV_ERROR_UNINITIALIZED.rawValue
    }

    func observe(_ name: String, format: mpv_format) {
        _ = withPointer { mpv_observe_property($0, 0, name, format) }
    }

    func set(_ name: String, string: String) {
        _ = withPointer { mpv_set_property_string($0, name, string) }
    }

    func set(_ name: String, flag: Bool) {
        withPointer { pointer in
            var value: Int32 = flag ? 1 : 0
            mpv_set_property(pointer, name, MPV_FORMAT_FLAG, &value)
        }
    }

    func set(_ name: String, double: Double) {
        withPointer { pointer in
            var value = double
            mpv_set_property(pointer, name, MPV_FORMAT_DOUBLE, &value)
        }
    }

    func string(_ name: String) -> String? {
        withPointer { pointer -> String? in
            guard let cString = mpv_get_property_string(pointer, name) else { return nil }
            defer { mpv_free(cString) }
            return String(cString: cString)
        } ?? nil
    }

    func double(_ name: String) -> Double? {
        withPointer { Self.double(name, pointer: $0) } ?? nil
    }

    /// Stops playback and destroys the handle asynchronously. `keepAlive` (the render layer) is
    /// retained until mpv has released its video output.
    func destroy(keepAlive: AnyObject? = nil) {
        lock.lock()
        let pointer = self.pointer
        self.pointer = nil
        lock.unlock()
        guard let pointer else { return }

        nonisolated(unsafe) let handlePointer = pointer
        nonisolated(unsafe) let keepAlive = keepAlive
        queue.async {
            mpv_set_wakeup_callback(handlePointer, nil, nil)
            mpv_terminate_destroy(handlePointer)
            withExtendedLifetime(keepAlive) {}
            Unmanaged.passUnretained(self).release()
        }
    }

    // MARK: - Events

    private func withPointer<T>(_ body: (OpaquePointer) -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard let pointer else { return nil }
        return body(pointer)
    }

    private func scheduleDrain() {
        queue.async { self.drain() }
    }

    private func drain() {
        let events: [Event] = withPointer { pointer in
            var events: [Event] = []
            while let event = mpv_wait_event(pointer, 0)?.pointee, event.event_id != MPV_EVENT_NONE {
                if let converted = Self.convert(event, pointer: pointer) {
                    events.append(converted)
                }
            }
            return events
        } ?? []
        if !events.isEmpty {
            onEvents(events)
        }
    }

    private static func convert(_ event: mpv_event, pointer: OpaquePointer) -> Event? {
        switch event.event_id {
        case MPV_EVENT_PROPERTY_CHANGE:
            guard let data = event.data else { return nil }
            let property = data.assumingMemoryBound(to: mpv_event_property.self).pointee
            let name = String(cString: property.name)
            let value = Self.value(of: property)
            if name == "sub-text" {
                guard case let .string(text) = value else { return .subtitle(text: nil, start: nil, end: nil) }
                return .subtitle(
                    text: text,
                    start: double("sub-start", pointer: pointer),
                    end: double("sub-end", pointer: pointer)
                )
            }
            return .property(name: name, value: value)
        case MPV_EVENT_FILE_LOADED:
            return .fileLoaded
        case MPV_EVENT_PLAYBACK_RESTART:
            return .playbackRestart
        case MPV_EVENT_END_FILE:
            guard let data = event.data else { return nil }
            let endFile = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
            guard endFile.reason == MPV_END_FILE_REASON_ERROR else { return nil }
            return .endFile(error: String(cString: mpv_error_string(endFile.error)))
        default:
            return nil
        }
    }

    private static func value(of property: mpv_event_property) -> Value {
        guard let data = property.data else { return .none }
        switch property.format {
        case MPV_FORMAT_FLAG:
            return .flag(data.assumingMemoryBound(to: Int32.self).pointee != 0)
        case MPV_FORMAT_INT64:
            return .int(data.assumingMemoryBound(to: Int64.self).pointee)
        case MPV_FORMAT_DOUBLE:
            return .double(data.assumingMemoryBound(to: Double.self).pointee)
        case MPV_FORMAT_STRING:
            guard let cString = data.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee else { return .none }
            return .string(String(cString: cString))
        default:
            return .none
        }
    }

    private static func double(_ name: String, pointer: OpaquePointer) -> Double? {
        var value = 0.0
        return mpv_get_property(pointer, name, MPV_FORMAT_DOUBLE, &value) >= 0 ? value : nil
    }
}
