import Foundation
import CoreAudio
import AudioToolbox
import os

public enum CoreAudioValueSize {
    public static let uint32 = UInt32(MemoryLayout<UInt32>.size)
}

public enum AsyncWorkOwnership {
    public static func enqueue<T: AnyObject & Sendable>(
        owner: T,
        on queue: DispatchQueue,
        operation: @escaping @Sendable (T) -> Void
    ) {
        queue.async {
            operation(owner)
        }
    }
}

/// System-level per-process audio tap engine (macOS 18+).
///
/// A process tap captures a process's output audio before the system mix,
/// routes it through a private aggregate device, and lets this app apply a
/// real gain (0...1) in the IO callback. Starting the aggregate device lets
/// macOS request system-audio capture permission when it is needed.
public final class ProcessTapEngine: @unchecked Sendable {
    private struct State {
        var isActive = false
        var lastError: String?
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let realtimeGain = RealtimeGain(initialValue: 1)
    private let queue = DispatchQueue(label: "com.codex.app-volume-control.tap")

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var processObjectIDs: [AudioObjectID] = []
    private var outputDeviceListener: AudioObjectPropertyListenerBlock?
    private var observedOutputDeviceID: AudioObjectID?
    private var deviceRestartPending = false
    private var stackedInputOffset = 0
    private var rampCoefficient: Float = 0.0007

    public init() {}

    public var volume: Float {
        get { realtimeGain.target }
        set { realtimeGain.setTarget(newValue) }
    }

    public var isActive: Bool {
        lock.withLock { $0.isActive }
    }

    public var lastError: String? {
        lock.withLock { $0.lastError }
    }

    /// Starts (or restarts) the tap for the given audio process objects.
    /// Runs asynchronously so the main thread never blocks on CoreAudio.
    public func start(processObjectIDs: [AudioObjectID], volume: Float) {
        let objects = Array(Set(processObjectIDs)).sorted()
        guard !objects.isEmpty else { return }
        AsyncWorkOwnership.enqueue(owner: self, on: queue) { engine in
            if engine.isActive, engine.processObjectIDs == objects {
                engine.volume = volume
                return
            }
            engine._stopInternal()
            engine.processObjectIDs = objects
            engine._startInternal(processObjectIDs: objects, volume: volume)
        }
    }

    public func stop() {
        AsyncWorkOwnership.enqueue(owner: self, on: queue) { engine in
            engine._stopInternal()
        }
    }

    public func setVolume(_ value: Float) {
        volume = value
    }

    // MARK: - Lifecycle

    private func _startInternal(processObjectIDs: [AudioObjectID], volume: Float) {
        guard #available(macOS 18, *) else {
            fail("需要 macOS 18 或更高版本")
            return
        }
        self.volume = volume
        lock.withLock { $0.lastError = nil }

        let description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        let tapUUID = UUID()
        description.uuid = tapUUID
        description.name = "AppVolumeControl"
        description.muteBehavior = CATapMuteBehavior.mutedWhenTapped

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let createStatus = AudioHardwareCreateProcessTap(description, &newTapID)
        guard createStatus == noErr else {
            fail("创建进程 tap 失败 (\(createStatus))")
            return
        }
        tapID = newTapID

        guard let outputDeviceID = defaultOutputDeviceID(),
              let outputDeviceUID = deviceUID(outputDeviceID) else {
            fail("无法获取默认输出设备")
            return
        }

        let outputTransport = transportType(outputDeviceID)
        let outputRate = sampleRate(outputDeviceID)
        let isBluetooth = outputTransport == kAudioDeviceTransportTypeBluetooth
            || outputTransport == kAudioDeviceTransportTypeBluetoothLE

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AppVolumeControl-Aggregate",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: isBluetooth,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputDeviceUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapUUID.uuidString
                ]
            ]
        ]

        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID)
        guard aggregateStatus == noErr else {
            fail("创建聚合设备失败 (\(aggregateStatus))")
            return
        }
        aggregateID = newAggregateID

        guard waitForDeviceReady(deviceID: aggregateID, timeout: 3) else {
            fail("聚合设备未就绪")
            return
        }

        if let outputRate, sampleRate(aggregateID) != outputRate {
            setSampleRate(deviceID: aggregateID, sampleRate: outputRate)
            CFRunLoopRunInMode(.defaultMode, 0.1, false)
        }

        let outputBufferSize = bufferFrameSize(deviceID: outputDeviceID)
        let aggregateBufferSize = bufferFrameSize(deviceID: aggregateID)
        if outputBufferSize > 0, aggregateBufferSize != outputBufferSize {
            setBufferFrameSize(deviceID: aggregateID, size: outputBufferSize)
        }

        setClockSource(aggregateID: aggregateID, masterUID: outputDeviceUID)

        let stackedOffset: Int
        if isBluetooth {
            stackedOffset = inputChannelCount(deviceID: outputDeviceID)
        } else {
            stackedOffset = 0
        }

        stackedInputOffset = stackedOffset
        if let rate = sampleRate(aggregateID), rate > 0 {
            rampCoefficient = 1 - exp(-1 / (Float(rate) * 0.030))
        } else {
            rampCoefficient = 0.0007
        }

        guard let format = streamFormat(deviceID: aggregateID, scope: kAudioObjectPropertyScopeInput),
              isFloat32(format) else {
            fail("聚合设备使用了不支持的音频格式")
            return
        }

        var newProcID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&newProcID, aggregateID, nil) { [weak self] _, inInputData, _, outOutputData, _ in
            guard let self else { return }
            self.processAudio(input: inInputData, output: outOutputData)
        }
        guard procStatus == noErr, let newProcID else {
            fail("创建 IO 回调失败 (\(procStatus))")
            return
        }
        ioProcID = newProcID

        let startStatus = AudioDeviceStart(aggregateID, ioProcID)
        guard startStatus == noErr else {
            fail("启动音频 IO 失败 (\(startStatus))")
            return
        }

        lock.withLock { $0.isActive = true }
        registerOutputDeviceListener()
    }

    private func _stopInternal() {
        let aggregate = aggregateID
        let proc = ioProcID
        let tap = tapID

        aggregateID = AudioObjectID(kAudioObjectUnknown)
        ioProcID = nil
        tapID = AudioObjectID(kAudioObjectUnknown)
        processObjectIDs = []
        removeOutputDeviceListener()

        if let proc, aggregate != AudioObjectID(kAudioObjectUnknown) {
            AudioDeviceStop(aggregate, proc)
            AudioDeviceDestroyIOProcID(aggregate, proc)
        }
        if aggregate != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregate)
        }
        if tap != AudioObjectID(kAudioObjectUnknown) {
            if #available(macOS 18, *) {
                AudioHardwareDestroyProcessTap(tap)
            }
        }
        deviceRestartPending = false
        lock.withLock { $0.isActive = false }
    }

    private func fail(_ message: String) {
        lock.withLock { $0.lastError = message }
        _stopInternal()
    }

    // MARK: - Audio callback

    private func processAudio(
        input inInputData: UnsafePointer<AudioBufferList>,
        output outOutputData: UnsafeMutablePointer<AudioBufferList>
    ) {
        let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
        let outputBuffers = UnsafeMutableAudioBufferListPointer(outOutputData)

        for (outputIndex, outputBuffer) in outputBuffers.enumerated() {
            guard let outputData = outputBuffer.mData else { continue }
            let inputIndex = outputIndex + stackedInputOffset
            let outputSampleCount = Int(outputBuffer.mDataByteSize) / MemoryLayout<Float>.size
            let outputSamples = outputData.assumingMemoryBound(to: Float.self)

            guard inputIndex < inputBuffers.count,
                  let inputData = inputBuffers[inputIndex].mData else {
                memset(outputData, 0, Int(outputBuffer.mDataByteSize))
                continue
            }

            let inputSampleCount = Int(inputBuffers[inputIndex].mDataByteSize) / MemoryLayout<Float>.size
            let inputSamples = inputData.assumingMemoryBound(to: Float.self)
            let count = min(inputSampleCount, outputSampleCount)
            realtimeGain.process(
                input: inputSamples,
                output: outputSamples,
                count: count,
                rampCoefficient: rampCoefficient
            )
            if outputSampleCount > count {
                memset(
                    outputData.advanced(by: count * MemoryLayout<Float>.size),
                    0,
                    (outputSampleCount - count) * MemoryLayout<Float>.size
                )
            }
        }
    }

    // MARK: - Device change handling

    private func registerOutputDeviceListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        observedOutputDeviceID = defaultOutputDeviceID()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self, self.isActive, !self.deviceRestartPending else { return }
                guard let currentDevice = self.defaultOutputDeviceID(),
                      currentDevice != self.observedOutputDeviceID else { return }
                self.deviceRestartPending = true
                self.queue.asyncAfter(deadline: .now() + 0.20) { [weak self] in
                    guard let self else { return }
                    self.deviceRestartPending = false
                    guard self.isActive,
                          let currentDevice = self.defaultOutputDeviceID(),
                          currentDevice != self.observedOutputDeviceID else { return }
                    self.observedOutputDeviceID = currentDevice
                    let objects = self.processObjectIDs
                    let currentVolume = self.volume
                    self._stopInternal()
                    self.processObjectIDs = objects
                    self._startInternal(processObjectIDs: objects, volume: currentVolume)
                }
            }
        }
        outputDeviceListener = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
    }

    private func removeOutputDeviceListener() {
        guard let block = outputDeviceListener else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        outputDeviceListener = nil
        observedOutputDeviceID = nil
    }

    // MARK: - CoreAudio helpers

    private func defaultOutputDeviceID() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        return status == noErr && deviceID != AudioObjectID(kAudioObjectUnknown) ? deviceID : nil
    }

    private func deviceUID(_ deviceID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutableBytes(of: &uid) { rawBuffer in
            AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &size,
                rawBuffer.baseAddress!
            )
        }
        return status == noErr ? uid as String : nil
    }

    private func transportType(_ deviceID: AudioObjectID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport)
        return transport
    }

    private func sampleRate(_ deviceID: AudioObjectID) -> Float64? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
        return status == noErr ? rate : nil
    }

    private func bufferFrameSize(deviceID: AudioObjectID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = CoreAudioValueSize.uint32
        var value: UInt32 = 0
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        return value
    }

    private func streamFormat(
        deviceID: AudioObjectID,
        scope: AudioObjectPropertyScope
    ) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &format
        )
        return status == noErr ? format : nil
    }

    private func isFloat32(_ format: AudioStreamBasicDescription) -> Bool {
        format.mFormatID == kAudioFormatLinearPCM
            && format.mBitsPerChannel == 32
            && (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
            && format.mChannelsPerFrame > 0
            && (format.mBytesPerFrame == 4
                || format.mBytesPerFrame == format.mChannelsPerFrame * 4)
    }

    private func setBufferFrameSize(deviceID: AudioObjectID, size: UInt32) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = size
        AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    private func setSampleRate(deviceID: AudioObjectID, sampleRate: Float64) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate = sampleRate
        AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<Float64>.size), &rate)
    }

    private func setClockSource(aggregateID: AudioObjectID, masterUID: String) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyMainSubDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString = masterUID as CFString
        _ = withUnsafePointer(to: &uid) { pointer in
            AudioObjectSetPropertyData(
                aggregateID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<CFString>.size),
                UnsafeMutableRawPointer(mutating: pointer)
            )
        }
    }

    private func waitForDeviceReady(deviceID: AudioObjectID, timeout: TimeInterval) -> Bool {
        let deadline = CFAbsoluteTimeGetCurrent() + timeout
        while CFAbsoluteTimeGetCurrent() < deadline {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsAlive,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var isAlive: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &isAlive)
            if status == noErr, isAlive != 0 {
                return true
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return false
    }

    private func inputChannelCount(deviceID: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }
        let rawBuffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        let bufferList = rawBuffer.assumingMemoryBound(to: AudioBufferList.self)
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bufferList) == noErr else {
            return 0
        }
        let list = UnsafeMutableAudioBufferListPointer(bufferList)
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
