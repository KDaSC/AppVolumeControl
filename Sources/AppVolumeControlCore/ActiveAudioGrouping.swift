public struct ActiveAudioProcess: Equatable, Sendable {
    public let pid: Int32
    public let objectID: UInt32
    public let isRunningOutput: Bool

    public init(pid: Int32, objectID: UInt32, isRunningOutput: Bool) {
        self.pid = pid
        self.objectID = objectID
        self.isRunningOutput = isRunningOutput
    }
}

public enum ActiveAudioGrouping {
    public static func visibleProcessIDs(from processes: [ActiveAudioProcess]) -> [Int32] {
        processes
            .filter(\.isRunningOutput)
            .map(\.pid)
            .sorted()
    }

    public static func sortedObjectIDs(_ objectIDs: [UInt32]) -> [UInt32] {
        Array(Set(objectIDs)).sorted()
    }
}
