import CoreAudio
import Foundation

/// 被动监听进程列表、发声和设备变化；没有轮询。 / Event-only audio discovery, no polling.
@MainActor
public final class AudioOutputObserver {
    private struct Key: Hashable {
        let object: AudioObjectID
        let selector: AudioObjectPropertySelector
    }
    private var listeners: [Key: AudioObjectPropertyListenerBlock] = [:]
    private var pending: DispatchWorkItem?
    private var handler: (@MainActor () -> Void)?
    private var restartHandler: (@MainActor () -> Void)?
    public private(set) var notificationCount = 0
    public private(set) var deliveryCount = 0
    public private(set) var lastError: OSStatus?
    public var listenerCount: Int { listeners.count }

    public init() {}

    public func start(onServiceRestart: @escaping @MainActor () -> Void = {}, onChange: @escaping @MainActor () -> Void) {
        stop()
        handler = onChange
        restartHandler = onServiceRestart
        lastError = nil
        rebuildListeners()
        schedule()
    }

    public func stop() {
        handler = nil
        restartHandler = nil
        pending?.cancel()
        pending = nil
        for key in Array(listeners.keys) { remove(key) }
    }

    private func schedule() {
        guard handler != nil else { return }
        notificationCount += 1
        // 短窗口合并事件；不延后已有任务，避免连续通知饥饿。 / Coalesce without starvation.
        guard pending == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.handler != nil else { return }
                self.pending = nil
                self.rebuildListeners()
                self.deliveryCount += 1
                self.handler?()
            }
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10, execute: item)
    }

    private func rebuildListeners() {
        lastError = nil
        let system = AudioObjectID(kAudioObjectSystemObject)
        var wanted: Set<Key> = [
            Key(object: system, selector: kAudioHardwarePropertyProcessObjectList),
            Key(object: system, selector: kAudioHardwarePropertyServiceRestarted),
            Key(object: system, selector: kAudioHardwarePropertyDefaultOutputDevice)
        ]
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size)
        if status == noErr {
            var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
            let readStatus = size == 0 ? noErr : AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects)
            if readStatus == noErr {
                for object in objects where object != kAudioObjectUnknown {
                    wanted.insert(Key(object: object, selector: kAudioProcessPropertyIsRunningOutput))
                    wanted.insert(Key(object: object, selector: kAudioProcessPropertyIsRunning))
                    wanted.insert(Key(object: object, selector: kAudioProcessPropertyDevices))
                }
            } else {
                lastError = readStatus
                // 瞬时列表读取失败时保留现有订阅。 / Retain subscriptions on transient read failure.
                wanted.formUnion(listeners.keys)
            }
        } else {
            lastError = status
            wanted.formUnion(listeners.keys)
        }
        for key in Set(listeners.keys).subtracting(wanted) { remove(key) }
        for key in wanted where listeners[key] == nil {
            var property = Self.listenerAddress(key.selector)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.handler != nil else { return }
                    if key.selector == kAudioHardwarePropertyServiceRestarted {
                        // HAL 重启使订阅与对象 ID 失效。 / Rebind invalidated HAL subscriptions.
                        for oldKey in Array(self.listeners.keys) { self.remove(oldKey) }
                        self.restartHandler?()
                    }
                    self.schedule()
                }
            }
            let result = AudioObjectAddPropertyListenerBlock(key.object, &property, .main, block)
            if result == noErr { listeners[key] = block }
            else { lastError = result }
        }
    }

    private func remove(_ key: Key) {
        guard let block = listeners.removeValue(forKey: key) else { return }
        var property = Self.listenerAddress(key.selector)
        AudioObjectRemovePropertyListenerBlock(key.object, &property, .main, block)
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func listenerAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        // 通知可能使用输出 scope；仅订阅 global 会漏掉真实发声事件。 / Match output-scoped events too.
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeWildcard,
                                   mElement: kAudioObjectPropertyElementWildcard)
    }
}
