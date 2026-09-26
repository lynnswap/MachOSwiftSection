import Foundation
import Testing
import SwiftDiffing
@testable import swift_section

struct DiffOutputTests {
    @Test func summaryUsesTheRequestedOutputPath() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("snapshot.json")
        let output = directory.appendingPathComponent("summary.txt")
        let document = ABISnapshotDocument(snapshot: .init())
        try ABIJSON.encoder().encode(document).write(to: input)
        var command = try DiffCommand.parse([input.path, input.path, "--summary-only", "--output-path", output.path])
        try await command.run()
        let report = try String(contentsOf: output, encoding: .utf8)
        #expect(report.contains("ABI-breaking: false"))
        #expect(report.contains("backward-compatible: true"))
    }
}
