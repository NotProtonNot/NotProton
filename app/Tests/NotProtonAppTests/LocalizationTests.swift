import Foundation
import Testing

@testable import NotProtonApp

@Suite("Simplified Chinese localization")
struct LocalizationTests {
    @Test func bundledCatalog() {
        #expect(L10n.chinese != nil)
        #expect(L10n.tr("Status", language: "zh-Hans") == "状态")
        #expect(L10n.tr("Prefix Backups", language: "zh-CN") == "容器备份")
        #expect(L10n.tr("Status", language: "en") == "Status")
    }

    @Test func languageSelection() {
        for language in ["zh", "zh-Hans", "zh-CN", "zh_SG", "zh-Hans-CN"] {
            #expect(L10n.isSimplifiedChinese(language))
            #expect(L10n.tr("Status", language: language) == "状态")
        }
        for language in ["en", "en-US", "fr", "", "zh-Hant", "zh-TW", "zh-HK", "zh-Hant-CN"] {
            #expect(!L10n.isSimplifiedChinese(language))
            #expect(L10n.tr("Status", language: language) == "Status")
        }
        #expect(Bundle.preferredLocalizations(from: ["en", "zh-Hans"],
            forPreferences: ["zh-Hans-CN", "en"]) == ["zh-Hans"])
        #expect(Bundle.preferredLocalizations(from: ["en", "zh-Hans"],
            forPreferences: ["en-US", "zh-Hans"]) == ["en"])
    }

    @Test func dynamicValues() {
        let count = 3
        #expect(L10n.tr("Delete \(count) prefixes?", language: "zh-Hans") == "删除 3 个游戏容器？")
        #expect(L10n.tr("Delete \(count) prefixes?", language: "en") == "Delete 3 prefixes?")
        #expect(L10n.tr("Deleted \(count) backups for \("游戏").", language: "zh-Hans")
            == "已删除“游戏”的 3 个备份。")
    }

    @Test func everyBundledTranslation() throws {
        let bundle = try #require(L10n.chinese)
        let url = try #require(bundle.url(forResource: "Localizable", withExtension: "strings"))
        let table = try #require(PropertyListSerialization.propertyList(
            from: Data(contentsOf: url), format: nil) as? [String: String])
        #expect(!table.isEmpty)
        for (key, value) in table {
            let message = L10n.Message(stringLiteral: key)
            #expect(L10n.tr(message, language: "zh-Hans") == value)
            #expect(L10n.tr(message, language: "en") == key)
        }
    }

    @Test func namesAreNeverReinterpreted() {
        let game = #"游戏 100% "{1}" \ path"#
        #expect(L10n.tr("Delete the prefix for \(game)?", language: "zh-Hans")
            == "删除“\(game)”的游戏容器？")
        #expect(L10n.render("{1}/{0}/{1}", arguments: ["{1}", "100%"]) == "100%/{1}/100%")
    }

    @Test func fallbackAndUnknownPlaceholders() {
        #expect(L10n.tr("Untranslated \(42)", language: "zh-Hans") == "Untranslated 42")
        #expect(L10n.render("{9} {0}", arguments: ["safe"]) == "{9} safe")
    }

    @Test func destructiveWarningsStayExplicit() {
        #expect(L10n.tr("The game SAVE DATA inside the prefix WILL BE LOST.", language: "zh-Hans")
            == "容器内的游戏存档将永久丢失！")
        #expect(L10n.tr("Rebuild Without Backing Up", language: "zh-Hans") == "不备份，直接重建")
    }
}
