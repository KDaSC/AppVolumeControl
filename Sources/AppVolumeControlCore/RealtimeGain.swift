import AppVolumeControlRealtime

public final class RealtimeGain: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<AVCRealtimeGain>

    public init(initialValue: Float) {
        storage = .allocate(capacity: 1)
        storage.initialize(to: AVCRealtimeGain())
        avc_realtime_gain_init(storage, initialValue)
    }

    deinit {
        storage.deinitialize(count: 1)
        storage.deallocate()
    }

    public func setTarget(_ value: Float) {
        avc_realtime_gain_set_target(storage, value)
    }

    public var target: Float {
        avc_realtime_gain_target(storage)
    }

    public func process(
        input: UnsafePointer<Float>,
        output: UnsafeMutablePointer<Float>,
        count: Int,
        rampCoefficient: Float
    ) {
        guard count > 0 else { return }
        avc_realtime_gain_process(storage, input, output, count, rampCoefficient)
    }
}
