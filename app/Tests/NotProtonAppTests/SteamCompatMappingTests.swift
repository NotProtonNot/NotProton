import Foundation
import Testing
@testable import NotProtonApp

@Suite("Steam's compatibility tool mapping")
struct SteamCompatMappingTests {

    private let config = """
    "InstallConfigStore"
    {
    \t"Software"
    \t{
    \t\t"CompatToolMapping"
    \t\t{
    \t\t\t"10"
    \t\t\t{
    \t\t\t\t"name"\t\t"tool-a"
    \t\t\t\t"priority"\t\t"250"
    \t\t\t}
    \t\t\t"20"
    \t\t\t{
    \t\t\t\t"config"\t\t""
    \t\t\t\t"name"\t\t"tool-b"
    \t\t\t}
    \t\t}
    \t\t"apps"
    \t\t{
    \t\t\t"30"
    \t\t\t{
    \t\t\t\t"name"\t\t"not-a-mapping"
    \t\t\t}
    \t\t}
    \t}
    }
    """

    @Test("Each app's tool is read from its own entry")
    func readsEntries() {
        #expect(SteamCompatMapping.tool(forApp: "10", in: config) == "tool-a")
        #expect(SteamCompatMapping.tool(forApp: "20", in: config) == "tool-b")
    }

    @Test("Apps without an entry, or outside the mapping, have no tool")
    func missingEntries() {
        #expect(SteamCompatMapping.tool(forApp: "30", in: config) == nil)
        #expect(SteamCompatMapping.tool(forApp: "1", in: config) == nil)
        #expect(SteamCompatMapping.tool(forApp: "10", in: "\"InstallConfigStore\" { }") == nil)
    }
}
