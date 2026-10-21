import Foundation

enum Migration {
    enum Outcome: Equatable {
        case moved
        case nothingToMove
        case targetInUse
    }

    static func hasFiles(_ url: URL, fm: FileManager = .default) -> Bool {
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: []) else { return false }
        for case let item as URL in e {
            if (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { return true }
        }
        return false
    }

    @discardableResult
    static func move(from: URL, to: URL, fm: FileManager = .default) -> Outcome {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: from.path, isDirectory: &isDir), isDir.boolValue, from.standardizedFileURL != to.standardizedFileURL else {
            return .nothingToMove
        }
        if fm.fileExists(atPath: to.path) {
            guard !hasFiles(to, fm: fm) else { return .targetInUse }
            try? fm.removeItem(at: to)
        }
        try? fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try fm.moveItem(at: from, to: to)
            return .moved
        } catch {
            return .nothingToMove
        }
    }

    static func lockConfig(_ dir: URL, fm: FileManager = .default) {
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return }
        for case let item as URL in e where (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: item.path)
        }
    }

    static func previousNames(_ info: [String: Any] = Bundle.main.infoDictionary ?? [:]) -> [String] {
        (info["AppPreviousNames"] as? String ?? "")
            .split(whereSeparator: { $0 == "," || $0 == " " })
            .map(String.init)
            .filter { !$0.isEmpty && $0 != Identity.appName }
    }

    static func run(previous: [String] = previousNames(),
                    appName: String = Identity.appName,
                    configDir: String = Identity.configDirName,
                    home: URL = FileManager.default.homeDirectoryForCurrentUser,
                    support: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
                    fm: FileManager = .default) {
        for old in previous {
            move(from: support.appendingPathComponent(old, isDirectory: true),
                 to: support.appendingPathComponent(appName, isDirectory: true), fm: fm)
            let newConfig = home.appendingPathComponent(".config/\(configDir)", isDirectory: true)
            if move(from: home.appendingPathComponent(".config/\(old.lowercased())", isDirectory: true), to: newConfig, fm: fm) == .moved {
                lockConfig(newConfig, fm: fm)
            }
        }
    }
}
