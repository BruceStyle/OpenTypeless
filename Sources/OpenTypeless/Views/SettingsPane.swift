import Foundation

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, appearance, models, privacy
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "通用"
        case .appearance: return "外观"
        case .models: return "模型与连接"
        case .privacy: return "隐私与权限"
        }
    }
}
