// Run the real localization helper without SwiftUI or the Swift Testing module.
import Foundation

extension Bundle {
    static let module = Bundle(path: CommandLine.arguments[1])!
}

@main
enum LocalizationSmoke {
    static func main() {
        precondition(L10n.chinese != nil)
        let tableURL = L10n.chinese!.url(forResource: "Localizable", withExtension: "strings")!
        let table = try! PropertyListSerialization.propertyList(
            from: Data(contentsOf: tableURL), format: nil) as! [String: String]
        for (key, value) in table {
            let message = L10n.Message(stringLiteral: key)
            precondition(L10n.tr(message, language: "zh-Hans") == value)
            precondition(L10n.tr(message, language: "en") == key)
        }
        for language in ["zh", "zh-Hans", "zh-CN", "zh_SG", "zh-Hans-CN"] {
            precondition(L10n.tr("Status", language: language) == "状态")
        }
        for language in ["en", "en-US", "fr", "", "zh-Hant", "zh-TW", "zh-HK", "zh-Hant-CN"] {
            precondition(L10n.tr("Status", language: language) == "Status")
        }
        precondition(L10n.tr("Deleted \(3) backups for \("游戏").", language: "zh-CN")
            == "已删除“游戏”的 3 个备份。")
        let game = #"游戏 100% "{1}" \ path"#
        precondition(L10n.tr("Delete the prefix for \(game)?", language: "zh-Hans")
            == "删除“\(game)”的游戏容器？")
        precondition(L10n.render("{1}/{0}/{1}", arguments: ["{1}", "100%"]) == "100%/{1}/100%")
        precondition(L10n.tr("Untranslated \(42)", language: "zh-Hans") == "Untranslated 42")
        precondition(L10n.tr("The game SAVE DATA inside the prefix WILL BE LOST.", language: "zh-Hans")
            == "容器内的游戏存档将永久丢失！")
        precondition(L10n.tr("Rebuild Without Backing Up", language: "zh-Hans") == "不备份，直接重建")
        precondition(L10n.tr("Status") == (L10n.isSimplifiedChinese(L10n.language) ? "状态" : "Status"))
        if let expected = ProcessInfo.processInfo.environment["LOCALIZATION_EXPECTED_STATUS"] {
            precondition(L10n.tr("Status") == expected)
        }
        precondition(Bundle.preferredLocalizations(from: ["en", "zh-Hans"],
            forPreferences: ["zh-Hans-CN", "en"]) == ["zh-Hans"])
        precondition(Bundle.preferredLocalizations(from: ["en", "zh-Hans"],
            forPreferences: ["en-US", "zh-Hans"]) == ["en"])
        if CommandLine.arguments.count > 2 {
            let app = Bundle(path: CommandLine.arguments[2])!
            let packaged = AppResources.packaged(in: app)!
            precondition(packaged.bundleURL.standardizedFileURL == Bundle.module.bundleURL.standardizedFileURL)
            precondition(packaged.url(forResource: "payload", withExtension: nil) != nil)
            precondition(packaged.url(forResource: "detour2", withExtension: "bin") != nil)
            precondition(app.object(forInfoDictionaryKey: "NotProtonLanguage") == nil)
            precondition(app.object(forInfoDictionaryKey: "SUFeedURL") != nil)
            precondition(app.object(forInfoDictionaryKey: "SUPublicEDKey") != nil)
            precondition(Set(app.localizations).isSuperset(of: ["en", "zh-Hans"]))
            print("PASS: relocatable app resources, supported languages and retained updater")
        }
        print("PASS: Chinese/English runtime, language selection, interpolation and save warnings")
    }
}
