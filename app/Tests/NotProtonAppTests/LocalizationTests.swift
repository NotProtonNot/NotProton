import Foundation
import Testing

@testable import NotProtonApp

@Suite("Localization")
struct LocalizationTests {
    let chinese = Bundle.module.path(forResource: "zh-Hans", ofType: "lproj").flatMap(Bundle.init(path:))

    @Test("Chinese text is looked up with interpolated values in place")
    func chineseLookup() throws {
        let zh = try #require(chinese)
        #expect(String(localized: "Status", bundle: zh) == "状态")
        #expect(String(localized: "Delete \(3) prefixes?", bundle: zh) == "删除 3 个游戏容器？")
    }

    @Test("Chinese text can put interpolated values in another order")
    func chineseReorders() throws {
        let zh = try #require(chinese)
        #expect(String(localized: "Opened \("Wine Configuration") in \("Zuma Deluxe").", bundle: zh)
            == "已在“Zuma Deluxe”中打开Wine Configuration。")
    }

    let italian = Bundle.module.path(forResource: "it", ofType: "lproj").flatMap(Bundle.init(path:))

    @Test("Italian text is looked up with interpolated values in place")
    func italianLookup() throws {
        let it = try #require(italian)
        #expect(String(localized: "Status", bundle: it) == "Stato")
        #expect(String(localized: "Delete \(3) prefixes?", bundle: it) == "Eliminare 3 prefissi?")
        #expect(String(localized: "Opened \("Wine Configuration") in \("Zuma Deluxe").", bundle: it)
            == "Aperto Wine Configuration in Zuma Deluxe.")
    }

    let german = Bundle.module.path(forResource: "de", ofType: "lproj").flatMap(Bundle.init(path:))

    @Test("German text is looked up with interpolated values in place")
    func germanLookup() throws {
        let de = try #require(german)
        #expect(String(localized: "Prefixes", bundle: de) == "Präfixe")
        #expect(String(localized: "Delete \(3) prefixes?", bundle: de) == "3 Präfixe löschen?")
        #expect(String(localized: "Opened \("Wine Configuration") in \("Zuma Deluxe").", bundle: de)
            == "Wine Configuration in Zuma Deluxe geöffnet.")
    }

    let french = Bundle.module.path(forResource: "fr", ofType: "lproj").flatMap(Bundle.init(path:))

    @Test("French text is looked up with interpolated values in place")
    func frenchLookup() throws {
        let fr = try #require(french)
        #expect(String(localized: "Status", bundle: fr) == "État")
        #expect(String(localized: "Delete \(3) prefixes?", bundle: fr) == "Supprimer 3 préfixes\u{00A0}?")
        #expect(String(localized: "Opened \("Wine Configuration") in \("Zuma Deluxe").", bundle: fr)
            == "Wine Configuration ouvert dans Zuma Deluxe.")
    }

    @Test("A string not yet translated into one language shows English there")
    func pendingTranslationFallsBack() throws {
        let zh = try #require(chinese)
        let it = try #require(italian)
        #expect(String(localized: "The trial version is not supported.", bundle: zh)
            == "The trial version is not supported.")
        #expect(String(localized: "The trial version is not supported.", bundle: it)
            == "La versione di prova non è supportata.")
    }
}
