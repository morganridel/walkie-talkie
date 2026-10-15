import Foundation

/// An explicit local recognition language avoids a wrong automatic guess.
/// Automatic remains the default, including any configured helper allowlist.
enum WhisperLanguage: String, CaseIterable {
    case automatic = "auto"
    case english = "en"
    case french = "fr"

    static let preferenceKey = "localWhisperLanguage"
    static var selected: Self {
        get { fromStored(UserDefaults.standard.string(forKey: preferenceKey)) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: preferenceKey) }
    }
    static func fromStored(_ value: String?) -> Self {
        value.flatMap(Self.init(rawValue:)) ?? .automatic
    }
    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .english: return "English"
        case .french: return "French"
        }
    }
    func request(_ fields: [String: Any]) -> [String: Any] {
        var fields = fields
        if self != .automatic { fields["language"] = rawValue }
        return fields
    }
}
