import Foundation

enum Identity {
    private static let info = Bundle.main.infoDictionary ?? [:]
    nonisolated(unsafe) static var appName = info["CFBundleDisplayName"] as? String
        ?? info["CFBundleName"] as? String
        ?? ProcessInfo.processInfo.processName
    static let bundleId = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
    static let configDirName = info["AppConfigDirName"] as? String ?? appName.lowercased()
    nonisolated(unsafe) static var version: String = {
        let v = info["CFBundleShortVersionString"] as? String ?? "?"
        let b = info["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }()
}
