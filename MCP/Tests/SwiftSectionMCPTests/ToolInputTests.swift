import Foundation
import MCP
import Testing
@testable import swift_section_mcp

struct ToolInputTests {
    private func thinImage() -> Data {
        var data = Data()
        for raw: UInt32 in [0xfeedfacf, 0x0100000c, 0, 6, 0, 0, 0, 0] {
            var value = raw.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        return data
    }

    private func image(fat: Bool) -> Data {
        guard fat else { return thinImage() }
        var data = Data()
        for raw: UInt32 in [0xcafebabe, 1, 0x0100000c, 0, 0x100, 32, 8] {
            var value = raw.bigEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        data.append(Data(count: 0x100 - data.count))
        data.append(thinImage())
        return data
    }

    @Test(arguments: [false, true])
    func requestedArchitectureMustExist(fat: Bool) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try image(fat: fat).write(to: url)
        let session = BinarySession()
        let loaded = try await session.load(path: url.path, architecture: "arm64")
        #expect(loaded.contains("CPU_TYPE_ARM64"))
        for architecture in ["x86_64", "not-an-architecture"] {
            do {
                _ = try await session.load(path: url.path, architecture: architecture)
                Issue.record("Accepted an unavailable architecture")
            } catch SessionError.invalidArchitecture {
                #expect(await session.filePath == url.path)
            }
        }
    }

    @Test func conflictingSelectorsFailBeforeOpeningTheCache() async throws {
        let handler = ToolHandler(session: BinarySession())
        let result = await handler.handle(.init(name: "open_dyld_cache_image", arguments: [
            "imageName": .string("First"), "imagePath": .string("/Different"),
            "cachePath": .string("/does/not/exist"),
        ]))
        #expect(result.isError == true)
        #expect(try text(result).contains("not both"))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MCP_FIELD_LAYOUT_FIXTURE"] != nil))
    func fieldOffsetOptionChangesOfflineOutput() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["MCP_FIELD_LAYOUT_FIXTURE"])
        let session = BinarySession()
        _ = try await session.load(path: path)
        let handler = ToolHandler(session: session)
        let plain = await handler.handle(.init(name: "dump_type", arguments: ["name": .string("FixtureRecord")]))
        let annotated = await handler.handle(.init(name: "dump_type", arguments: ["name": .string("FixtureRecord"), "includeFieldOffsets": .bool(true)]))
        #expect(plain.isError != true)
        #expect(annotated.isError != true)
        let plainText = try text(plain)
        let annotatedText = try text(annotated)
        #expect(plainText.contains("first"))
        #expect(annotatedText != plainText)
        #expect(annotatedText.contains("offset"))
    }

    private func text(_ result: CallTool.Result) throws -> String {
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
        let content = try #require(object["content"] as? [[String: Any]])
        return content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
}
