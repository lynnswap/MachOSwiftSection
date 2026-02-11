import Demangling
import Semantic

/// A lightweight `NodePrinterTarget` that records atomic semantic components directly.
///
/// `SemanticString` is optimized for general-purpose composition and caching, but node printers
/// perform many small writes and frequently query `count` as a position marker. Using a simple
/// buffer avoids repeated tree flattening and reduces allocation overhead in hot paths.
package struct SemanticStringTarget: NodePrinterTarget {
    package init() {}

    private var position: Int = 0
    private var atomicComponents: [AtomicComponent] = []
    private var lastType: SemanticType? = nil

    package var count: Int { position }

    package mutating func write(_ content: String) {
        write(content, type: .standard)
    }

    package mutating func write(_ content: String, context: NodePrintContext?) {
        guard let context else {
            write(content)
            return
        }

        switch context.state {
        case .printFunctionParameters:
            write(content, type: .function(.declaration))
        case .printIdentifier:
            let semanticType: SemanticType
            switch context.node?.parent?.kind {
            case .function:
                semanticType = .function(.declaration)
            case .variable:
                semanticType = .variable
            case .enum:
                semanticType = .type(.enum, .name)
            case .structure:
                semanticType = .type(.struct, .name)
            case .class:
                semanticType = .type(.class, .name)
            case .protocol:
                semanticType = .type(.protocol, .name)
            default:
                semanticType = .standard
            }
            write(content, type: semanticType)
        case .printModule:
            write(content, type: .other)
        case .printKeyword:
            write(content, type: .keyword)
        case .printType:
            write(content, type: .type(.other, .name))
        }
    }

    package func buildSemanticString() -> SemanticString {
        SemanticString(components: atomicComponents)
    }

    private mutating func write(_ content: String, type: SemanticType) {
        guard !content.isEmpty else { return }

        // Monotonic marker for node printer logic. This is intentionally independent of the
        // atomic component count so we can coalesce adjacent components safely.
        position += 1

        if lastType == type, let lastIndex = atomicComponents.indices.last {
            let last = atomicComponents[lastIndex]
            var merged = last.string
            merged.append(content)
            atomicComponents[lastIndex] = .init(string: merged, type: type)
        } else {
            atomicComponents.append(.init(string: content, type: type))
            lastType = type
        }
    }
}

