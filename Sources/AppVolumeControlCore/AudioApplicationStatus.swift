public enum AudioApplicationStatus {
    public static let processGainText = "输出增益"
    public static let processGainConnectedText = "输出增益已连接"
    public static let unknownVolumeText = "音量未知"
    public static let unarmedProcessGainText = "原始输出 · 未启用独立增益"
    public static let enableProcessGainText = "启用独立增益"

    public static func unavailableText(isRunningOutput: Bool) -> String {
        isRunningOutput ? "正在输出 · 无独立音量接口" : "已识别 · 无独立音量接口"
    }
}
