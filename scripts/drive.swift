// Sends a command to a running Debug build of VidFlow (see VidFlow/App/DebugDriver.swift).
//   swiftc scripts/drive.swift -o build/drive && build/drive "sidebar new"
import Foundation

DistributedNotificationCenter.default().postNotificationName(
    .init("VidFlowDebug"), object: CommandLine.arguments.dropFirst().joined(separator: " "), userInfo: nil, deliverImmediately: true)
RunLoop.current.run(until: Date().addingTimeInterval(0.2))
