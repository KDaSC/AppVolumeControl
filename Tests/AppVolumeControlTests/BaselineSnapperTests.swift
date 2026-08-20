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
