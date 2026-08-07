import Foundation

enum AppVersionDisplay {
    static func text(from rawValue: Any?) -> String? {
        guard let rawVersion = rawValue as? String else {
            return nil
        }
        let version = rawVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty else {
            return nil
        }
        return "v\(version)"
    }

    static var current: String? {
        text(
            from: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            )
        )
    }
}
