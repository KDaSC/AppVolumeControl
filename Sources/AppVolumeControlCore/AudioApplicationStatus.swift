public enum AudioApplicationStatus {
    public static func unavailableText(isRunningOutput: Bool) -> String {
        isRunningOutput ? "正在输出 · 无独立音量接口" : "已识别 · 无独立音量接口"
    }
}
