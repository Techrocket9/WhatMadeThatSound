import CoreAudio
import Foundation

/// Thin, typed wrappers over the Core Audio HAL property API.
enum HAL {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func objectIDs(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> [AudioObjectID]? {
        var address = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr else { return nil }
        let capacity = Int(size) / MemoryLayout<AudioObjectID>.size
        guard capacity > 0 else { return [] }
        var ids = [AudioObjectID](repeating: kAudioObjectUnknown, count: capacity)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return nil }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static func objectID(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> AudioObjectID? {
        guard let value: AudioObjectID = scalar(object, selector), value != kAudioObjectUnknown else { return nil }
        return value
    }

    static func scalar<T: BitwiseCopyable>(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> T? {
        var address = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr,
              size == UInt32(MemoryLayout<T>.size)
        else { return nil }
        return pointer.load(as: T.self)
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

/// A registered HAL property listener that stays registered until invalidated.
final class PropertyListener {
    private let objectID: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock
    private var isRegistered = false

    /// Registers `handler` to run on `queue` whenever the property changes.
    /// Returns `nil` if the object doesn't support listening to the property.
    init?(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) {
        self.objectID = objectID
        self.address = HAL.address(selector, scope: scope)
        self.queue = queue
        self.block = { _, _ in handler() }
        guard AudioObjectAddPropertyListenerBlock(objectID, &address, queue, block) == noErr else { return nil }
        isRegistered = true
    }

    func invalidate() {
        guard isRegistered else { return }
        isRegistered = false
        // Fails harmlessly if the object has already gone away.
        AudioObjectRemovePropertyListenerBlock(objectID, &address, queue, block)
    }

    deinit {
        invalidate()
    }
}
