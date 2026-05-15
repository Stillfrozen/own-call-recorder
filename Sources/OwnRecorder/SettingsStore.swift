import Foundation

enum SummaryProvider: String {
    case api
    case cursorAgent = "cursor_agent"
}

enum STTProvider: String {
    case xai
    case groq
}

struct RecorderSettings {
    var summaryProvider: SummaryProvider
    var sttProvider: STTProvider
    var xaiSttLanguage: String
    var groqModel: String
    var summaryApiModel: String
    var cursorAgentBin: String
    var cursorModel: String
    var startHotkey: String
    var stopHotkey: String
    var notificationsEnabled: Bool
}

final class SettingsStore {
    static let shared = SettingsStore()

    private enum Key {
        static let summaryProvider = "settings.summaryProvider"
        static let sttProvider = "settings.sttProvider"
        static let xaiSttLanguage = "settings.xaiSttLanguage"
        static let groqModel = "settings.groqModel"
        static let summaryApiModel = "settings.summaryApiModel"
        static let cursorAgentBin = "settings.cursorAgentBin"
        static let cursorModel = "settings.cursorModel"
        static let startHotkey = "settings.startHotkey"
        static let stopHotkey = "settings.stopHotkey"
        static let notificationsEnabled = "settings.notificationsEnabled"
    }

    private let defaults = UserDefaults.standard

    private init() {}

    func load() -> RecorderSettings {
        let providerRaw = defaults.string(forKey: Key.summaryProvider) ?? SummaryProvider.api.rawValue
        let provider = SummaryProvider(rawValue: providerRaw) ?? .api
        let sttProviderRaw = defaults.string(forKey: Key.sttProvider) ?? STTProvider.xai.rawValue
        let sttProvider = STTProvider(rawValue: sttProviderRaw) ?? .xai

        let rawLanguage = defaults.string(forKey: Key.xaiSttLanguage) ?? "ru"
        let language = rawLanguage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedLanguage = language.isEmpty ? "ru" : language

        return RecorderSettings(
            summaryProvider: provider,
            sttProvider: sttProvider,
            xaiSttLanguage: normalizedLanguage,
            groqModel: defaults.string(forKey: Key.groqModel) ?? "whisper-large-v3-turbo",
            summaryApiModel: defaults.string(forKey: Key.summaryApiModel) ?? "claude-sonnet-4-20250514",
            cursorAgentBin: defaults.string(forKey: Key.cursorAgentBin) ?? "agent",
            cursorModel: defaults.string(forKey: Key.cursorModel) ?? "sonnet-4",
            startHotkey: defaults.string(forKey: Key.startHotkey) ?? "cmd+shift+9",
            stopHotkey: defaults.string(forKey: Key.stopHotkey) ?? "cmd+shift+0",
            notificationsEnabled: defaults.object(forKey: Key.notificationsEnabled) as? Bool ?? true
        )
    }

    func save(_ settings: RecorderSettings) {
        defaults.set(settings.summaryProvider.rawValue, forKey: Key.summaryProvider)
        defaults.set(settings.sttProvider.rawValue, forKey: Key.sttProvider)
        defaults.set(settings.xaiSttLanguage, forKey: Key.xaiSttLanguage)
        defaults.set(settings.groqModel, forKey: Key.groqModel)
        defaults.set(settings.summaryApiModel, forKey: Key.summaryApiModel)
        defaults.set(settings.cursorAgentBin, forKey: Key.cursorAgentBin)
        defaults.set(settings.cursorModel, forKey: Key.cursorModel)
        defaults.set(settings.startHotkey, forKey: Key.startHotkey)
        defaults.set(settings.stopHotkey, forKey: Key.stopHotkey)
        defaults.set(settings.notificationsEnabled, forKey: Key.notificationsEnabled)
    }
}
