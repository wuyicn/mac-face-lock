import SwiftUI

@MainActor
final class ThemeStore: ObservableObject {
    @Published private(set) var preferences: UIPreferences

    private let localStore: LocalJSONStore

    init(localStore: LocalJSONStore) {
        self.localStore = localStore
        self.preferences = localStore.readPreferences()
    }

    var preferredColorScheme: ColorScheme? {
        switch preferences.appearance {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    var accentColor: Color {
        switch preferences.accent {
        case .oceanBlue:
            return Color(red: 0.20, green: 0.48, blue: 0.96)
        case .guardianGreen:
            return Color(red: 0.28, green: 0.67, blue: 0.32)
        case .amethyst:
            return Color(red: 0.56, green: 0.32, blue: 0.86)
        }
    }

    func setAppearance(_ appearance: AppearanceMode) {
        var updated = preferences
        updated.appearance = appearance
        save(updated)
    }

    func setAccent(_ accent: AccentTheme) {
        var updated = preferences
        updated.accent = accent
        save(updated)
    }

    private func save(_ updated: UIPreferences) {
        guard (try? localStore.writePreferences(updated)) != nil else {
            return
        }
        preferences = updated
    }
}
