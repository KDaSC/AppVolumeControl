import Foundation
import AppVolumeControlCore
import CoreGraphics

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fatalError(message)
    }
}

expect(BaselineSnapper.value(0.72, baseline: 0.75) == 0.75, "2% should snap to the baseline")
expect(BaselineSnapper.value(0.719, baseline: 0.75) == 0.719, "3.1% should not snap")
expect(BaselineSnapper.value(0.42, baseline: nil) == 0.42, "missing baseline should not change the value")

let alignedFrame = PanelGeometry.frame(
    anchor: CGRect(x: 1000, y: 870, width: 24, height: 30),
    panelSize: CGSize(width: 386, height: 282),
    screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 870),
    gap: 0
)
expect(alignedFrame.maxY == 870, "panel must touch the menu bar boundary")
expect(abs(alignedFrame.midX - 1012) < 0.001, "panel must center on the status item")

let clampedFrame = PanelGeometry.frame(
    anchor: CGRect(x: 5, y: 870, width: 24, height: 30),
    panelSize: CGSize(width: 386, height: 282),
    screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 870),
    gap: 0
)
expect(clampedFrame.minX == 0, "panel must stay inside the left screen edge")

let secondaryDisplayFrame = PanelGeometry.frame(
    anchor: CGRect(x: -100, y: 1890, width: 24, height: 30),
    panelSize: CGSize(width: 386, height: 282),
    screenFrame: CGRect(x: -1440, y: 1000, width: 1440, height: 870),
    gap: 1
)
expect(secondaryDisplayFrame.maxY == 1869, "panel must preserve a one-point gap on a secondary display")
expect(secondaryDisplayFrame.minX >= -1440, "panel must stay inside a negative-origin display")

expect(
    AudioApplicationStatus.unavailableText(isRunningOutput: true) == "正在输出 · 无独立音量接口",
    "active unsupported apps need an honest output status"
)
expect(
    AudioApplicationStatus.unavailableText(isRunningOutput: false) == "已识别 · 无独立音量接口",
    "inactive unsupported apps need an honest discovery status"
)

expect(VolumePolicy.defaultLevel == 0.75, "all default targets must be 75%")
expect(
    VolumePolicy.migratedProcessGain(stored: 1, previousSchemaVersion: 1) == 0.75,
    "the legacy 100% Douyin default must migrate to 75%"
)
expect(
    VolumePolicy.migratedProcessGain(stored: 0.62, previousSchemaVersion: 1) == 0.62,
    "an explicit user gain must survive migration"
)
expect(
    VolumePolicy.migratedProcessGain(stored: 1, previousSchemaVersion: 2) == 0.75,
    "the previous 100% default must migrate even from schema 2"
)
expect(
    VolumeSettings.defaultValue.defaultOutputGain == 0.75,
    "新安装的默认输出增益必须是 75%"
)
expect(
    VolumeSettings.resolvedGain(
        settings: .defaultValue,
        storedGain: 0.42
    ) == 0.75,
    "默认设置不能沿用上一次应用的增益"
)

let firstSession = SessionIdentity(processID: 42, bundleIdentifier: "com.example.first")
let replacementSession = SessionIdentity(processID: 42, bundleIdentifier: "com.example.replacement")

expect(
    VolumePolicy.sessionGain(
        existingGain: 0.42,
        previousIdentity: firstSession,
        identity: firstSession,
        initialGain: 0.75
    ) == 0.42,
    "同一应用会话的当前增益不能被刷新覆盖"
)
expect(
    VolumePolicy.sessionGain(
        existingGain: 0.42,
        previousIdentity: firstSession,
        identity: replacementSession,
        initialGain: 0.60
    ) == 0.60,
    "相同 PID 的不同 bundle 不能继承旧会话增益"
)
expect(VolumePolicy.fallbackGain(candidates: [0, 0.50]) == 0.50, "恢复必须尊重非静音候选")
expect(VolumePolicy.fallbackGain(candidates: [0, 0]) == 0.75, "全零候选必须回到 75%")

let muteFromFortyTwo = VolumePolicy.toggleMute(
    currentGain: 0.42,
    restoreGain: nil,
    fallbackGain: 0.75
)
expect(muteFromFortyTwo.targetGain == 0, "42% 静音目标必须是 0%")
expect(muteFromFortyTwo.nextRestoreGain == 0.42, "静音必须记录 42%")
expect(muteFromFortyTwo.restoreGain(afterWriteSucceeded: false) == nil, "失败不能遗留恢复值")

let restoreToFortyTwo = VolumePolicy.toggleMute(
    currentGain: 0,
    restoreGain: 0.42,
    fallbackGain: 0.75
)
expect(restoreToFortyTwo.targetGain == 0.42, "恢复必须回到 42%")
expect(restoreToFortyTwo.nextRestoreGain == nil, "成功恢复后必须清除恢复值")
expect(restoreToFortyTwo.restoreGain(afterWriteSucceeded: false) == 0.42, "失败必须保留恢复值")

let restoreWithoutHistory = VolumePolicy.toggleMute(
    currentGain: 0,
    restoreGain: nil,
    fallbackGain: 0.50
)
expect(restoreWithoutHistory.targetGain == 0.50, "没有记录时必须使用回退值")
expect(VolumePolicy.isMuted(0.000_1), "阈值本身必须视为静音")
expect(!VolumePolicy.isMuted(0.000_11), "阈值以上必须视为非静音")
expect(VolumePolicy.shouldPersist(gain: 0.42, intent: .sliderCommit), "非零滑杆值可记忆")
expect(!VolumePolicy.shouldPersist(gain: 0, intent: .sliderCommit), "滑到 0% 不能覆盖记忆")
expect(!VolumePolicy.shouldPersist(gain: 0.42, intent: .temporaryMute), "按钮恢复不能改写记忆")
expect(
    !VolumePolicy.nativeReadAllowed(hasActiveWrite: true),
    "原生写入拥有当前会话时不能启动音量读取"
)
expect(
    VolumePolicy.nativeReadAllowed(hasActiveWrite: false),
    "没有原生写入时必须允许音量读取"
)
expect(
    VolumePolicy.resolvedNativeWriteGain(
        requestedGain: 0.42,
        confirmedGain: 0.75,
        succeeded: true
    ) == 0.42,
    "原生写入成功后显示值和确认值必须采用请求值"
)
expect(
    VolumePolicy.resolvedNativeWriteGain(
        requestedGain: 0.42,
        confirmedGain: 0.75,
        succeeded: false
    ) == 0.75,
    "原生写入失败后必须恢复之前确认的值"
)
expect(
    VolumePolicy.resolvedNativeWriteGain(
        requestedGain: 0.42,
        confirmedGain: nil,
        succeeded: false
    ) == nil,
    "没有确认值的原生写入失败后必须回到未知状态"
)

expect(
    ActiveAudioGrouping.visibleProcessIDs(from: [
        .init(pid: 10, objectID: 4, isRunningOutput: false),
        .init(pid: 20, objectID: 8, isRunningOutput: true)
    ]) == [20],
    "idle audio clients must not be displayed"
)
expect(
    ActiveAudioGrouping.sortedObjectIDs([9, 3, 9]) == [3, 9],
    "tap targets must be unique and stable"
)
expect(
    ProcessGainPlan.shouldRun(isOutputActive: true, gain: 0.75),
    "有输出且增益低于 100% 时应启动进程增益"
)
expect(
    !ProcessGainPlan.shouldRun(isOutputActive: false, gain: 0.75),
    "没有输出时不应启动进程增益"
)
expect(
    !ProcessGainPlan.shouldRun(isOutputActive: true, gain: 1),
    "100% 增益时不需要启动进程增益"
)
expect(
    ProcessGainPlan.shouldStartSystemAudioCapture(isOutputActive: true, gain: 0.75),
    "系统音频捕获不能被屏幕录制预检阻断"
)
expect(
    ProcessGainPlan.attachmentAllowed(explicitlyArmed: true, automaticallyAttachNewApps: false),
    "手动启用必须允许接管"
)
expect(
    ProcessGainPlan.attachmentAllowed(explicitlyArmed: false, automaticallyAttachNewApps: true),
    "自动设置必须允许接管"
)
expect(
    !ProcessGainPlan.attachmentAllowed(explicitlyArmed: false, automaticallyAttachNewApps: false),
    "全部关闭时不能接管"
)
expect(
    ProcessGainPlan.automaticAttachmentChanged(from: false, to: true),
    "打开自动接管必须立即触发一次重新协调"
)
expect(
    ProcessGainPlan.automaticAttachmentChanged(from: true, to: false),
    "关闭自动接管必须立即触发一次重新协调"
)
expect(
    !ProcessGainPlan.automaticAttachmentChanged(from: true, to: true),
    "自动接管设置不变时不能重复协调"
)
expect(
    ProcessGainPlan.action(
        isOutputActive: true,
        isAttachmentAllowed: true,
        gain: 0.50,
        requestedObjectIDs: [3, 9],
        currentObjectIDs: [3, 9],
        hasActiveEngine: true
    ) == .update(0.50),
    "改变滑块时只能更新增益，不能重启已连接的 tap"
)
expect(
    ProcessGainPlan.action(
        isOutputActive: true,
        isAttachmentAllowed: true,
        gain: 0.50,
        requestedObjectIDs: [3, 9],
        currentObjectIDs: [3, 9],
        hasActiveEngine: false
    ) == .none,
    "同一组对象的启动失败不能被轮询反复重试"
)
expect(
    ProcessGainPlan.action(
        isOutputActive: true,
        isAttachmentAllowed: true,
        gain: 0.50,
        requestedObjectIDs: [3, 9],
        currentObjectIDs: [3],
        hasActiveEngine: true
    ) == .start(objectIDs: [3, 9], gain: 0.50),
    "音频对象集合改变时才允许重建 tap"
)
expect(
    ProcessGainPlan.action(
        isOutputActive: true,
        isAttachmentAllowed: false,
        gain: 0.50,
        requestedObjectIDs: [3, 9],
        currentObjectIDs: nil,
        hasActiveEngine: false
    ) == .none,
    "未明确启用时不能自动接管应用输出"
)
expect(
    ProcessGainPlan.action(
        isOutputActive: true,
        isAttachmentAllowed: false,
        gain: 0.50,
        requestedObjectIDs: [3, 9],
        currentObjectIDs: [3, 9],
        hasActiveEngine: true
    ) == .stop,
    "关闭接管后必须停止既有 tap"
)
expect(
    ProcessGainPlan.shouldReleaseEngine(
        cleanupRequestIsCurrent: true,
        engineIsCurrent: true,
        hasReplacementTarget: false
    ),
    "当前引擎完成当前清理且没有替换目标时必须释放"
)
expect(
    !ProcessGainPlan.shouldReleaseEngine(
        cleanupRequestIsCurrent: true,
        engineIsCurrent: true,
        hasReplacementTarget: true
    ),
    "已有替换目标时必须保留同一引擎以保证队列顺序"
)
expect(
    !ProcessGainPlan.shouldReleaseEngine(
        cleanupRequestIsCurrent: false,
        engineIsCurrent: true,
        hasReplacementTarget: false
    ),
    "过期清理请求不能释放当前引擎"
)
expect(
    !ProcessGainPlan.shouldReleaseEngine(
        cleanupRequestIsCurrent: true,
        engineIsCurrent: false,
        hasReplacementTarget: false
    ),
    "旧引擎的清理回调不能释放替换引擎"
)

let realtimeGain = RealtimeGain(initialValue: 1)
realtimeGain.setTarget(0.5)
var inputSamples: [Float] = [1, 1, 1, 1]
var outputSamples = Array(repeating: Float.zero, count: inputSamples.count)
inputSamples.withUnsafeBufferPointer { input in
    outputSamples.withUnsafeMutableBufferPointer { output in
        realtimeGain.process(
            input: input.baseAddress!,
            output: output.baseAddress!,
            count: input.count,
            rampCoefficient: 1
        )
    }
}
expect(outputSamples == [0.5, 0.5, 0.5, 0.5], "实时增益必须在回调内立即应用新目标")

expect(
    AudioApplicationStatus.processGainText == "输出增益",
    "进程 tap 的数值必须明确是输出增益而不是应用内部音量"
)
expect(
    PanelLayout.height(applicationCount: 0, showsPermissionNotice: false) == 112,
    "没有输出应用时面板应保持紧凑"
)
expect(
    PanelLayout.height(applicationCount: 1, showsPermissionNotice: false) == 154,
    "一个应用时面板应按内容高度显示"
)
expect(
    PanelLayout.height(applicationCount: 12, showsPermissionNotice: true) == PanelLayout.maximumHeight,
    "应用较多时面板高度应有上限"
)

expect(
    CoreAudioValueSize.uint32 == 4,
    "CoreAudio 读取 UInt32 属性时必须提供四字节输出缓冲区"
)

final class LifetimeProbe: @unchecked Sendable {
    var didRun = false
}

var probe: LifetimeProbe? = LifetimeProbe()
weak var weakProbe = probe
let workFinished = DispatchSemaphore(value: 0)
AsyncWorkOwnership.enqueue(owner: probe!, on: DispatchQueue(label: "lifecycle-test")) { owner in
    owner.didRun = true
    workFinished.signal()
}
probe = nil
expect(
    workFinished.wait(timeout: .now() + 1) == .success,
    "queued cleanup must retain its owner until the cleanup runs"
)
expect(weakProbe == nil, "queued cleanup owner should be released after the work completes")

final class FIFOProbe: @unchecked Sendable {
    var events: [String] = []
}

let fifoProbe = FIFOProbe()
let fifoQueue = DispatchQueue(label: "lifecycle-fifo-test")
let fifoFinished = DispatchSemaphore(value: 0)
AsyncWorkOwnership.enqueue(owner: fifoProbe, on: fifoQueue) { owner in
    owner.events.append("cleanup")
}
AsyncWorkOwnership.enqueue(owner: fifoProbe, on: fifoQueue) { owner in
    owner.events.append("replacement")
    fifoFinished.signal()
}
expect(
    fifoFinished.wait(timeout: .now() + 1) == .success,
    "同一引擎队列上的替换启动必须完成"
)
expect(
    fifoProbe.events == ["cleanup", "replacement"],
    "同一引擎队列必须先清理旧路由再启动替换路由"
)

let noOpStopFinished = DispatchSemaphore(value: 0)
ProcessTapEngine().stop {
    noOpStopFinished.signal()
}
expect(
    noOpStopFinished.wait(timeout: .now() + 1) == .success,
    "无活动路由的停止也必须在生命周期队列上完成回调"
)
expect(
    noOpStopFinished.wait(timeout: .now() + 0.1) == .timedOut,
    "一次停止请求的完成回调只能执行一次"
)
