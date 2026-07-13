import Foundation
import Testing
import UIKit
@testable import keyboard

struct KeyboardTests {
    @Test func emojiBinaryContainsSearchAliases() throws {
        let store = try #require(EmojiStore(url: emojiBinaryURL()))
        let cryingEmoji = try #require(store.emoji(forWord: "cry"))

        #expect(store.emoji(forWord: "sob") == cryingEmoji)
        #expect(store.emoji(forWord: "sobbing") == cryingEmoji)
        #expect(store.search("cry").first == cryingEmoji)
        #expect(store.search("sob").first == cryingEmoji)
    }

    @Test func emojiSearchAvoidsSubstringNoise() throws {
        let store = try #require(EmojiStore(url: emojiBinaryURL()))
        let happyResults = store.search("happy")
        let rainResults = store.search("rain")

        #expect(happyResults.first == "😊")
        #expect(!happyResults.contains("😢"))
        #expect(!happyResults.contains("😭"))
        #expect(!rainResults.contains("🧠"))
        #expect(!rainResults.contains("🚆"))
    }

    @Test func emojiSearchUsesGeneratedUnicodeKeywords() throws {
        let store = try #require(EmojiStore(url: emojiBinaryURL()))
        let umbrellaResults = store.search("umbrella")

        #expect(umbrellaResults.contains("☂️") || umbrellaResults.contains("🌂"))
        #expect(store.search("umb").contains("☂️") || store.search("umb").contains("🌂"))
    }

    @Test func emojiBinaryProvidesDisplayCatalog() throws {
        let store = try #require(EmojiStore(url: emojiBinaryURL()))

        #expect(store.categoryCount > 0)
        #expect(!store.name(0).isEmpty)
        #expect(!store.icon(0).isEmpty)
        #expect(store.emojiCount(0) > 0)
        #expect(!store.emoji(0, 0).isEmpty)
    }

    private func emojiBinaryURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("keyboard/emoji.bin")
    }

    // MARK: Visual render checks — write PNGs of the emoji UI for eyeballing.
    // (The app target doesn't bundle emoji.bin, so the store is injected from the
    // repo file. PNGs land in keyboardTests/renders/, which is disposable.)

    @MainActor @Test func renderEmojiPalette() throws {
        let store = try #require(EmojiStore(url: emojiBinaryURL()))
        for dark in [false, true] {
            let theme = KeyboardTheme.system(dark: dark)
            let v = EmojiKeyboardView(theme: theme, showsGlobe: true, store: store)
            v.frame = CGRect(x: 0, y: 0, width: 390, height: 259)
            v.backgroundColor = dark ? UIColor(hex: 0x2A2A2E) : UIColor(hex: 0xE8E6EC)
            v.layoutIfNeeded()
            try writePNG(of: v, name: dark ? "emoji_palette_dark" : "emoji_palette_light")
        }
    }

    @MainActor @Test func renderEmojiSearchHeader() throws {
        let store = try #require(EmojiStore(url: emojiBinaryURL()))
        let theme = KeyboardTheme.system(dark: false)

        let hits = EmojiSearchHeader(theme: theme)
        hits.frame = CGRect(x: 0, y: 0, width: 390, height: EmojiSearchHeader.height)
        hits.backgroundColor = UIColor(hex: 0xE8E6EC)
        hits.update(query: "smile", results: store.search("smile"), showingRecents: false)
        hits.layoutIfNeeded()
        try writePNG(of: hits, name: "emoji_search_results")
        #expect(!store.search("smile").isEmpty)

        let miss = EmojiSearchHeader(theme: theme)
        miss.frame = hits.frame
        miss.backgroundColor = hits.backgroundColor
        miss.update(query: "zzzzqq", results: [], showingRecents: false)
        miss.layoutIfNeeded()
        try writePNG(of: miss, name: "emoji_search_empty")
    }

    @MainActor private func writePNG(of view: UIView, name: String) throws {
        let img = UIGraphicsImageRenderer(bounds: view.bounds).image { ctx in
            view.layer.render(in: ctx.cgContext)
        }
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("renders", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #require(img.pngData()).write(to: dir.appendingPathComponent("\(name).png"))
    }
}
