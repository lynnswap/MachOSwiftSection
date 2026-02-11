import Foundation
import MachOSwiftSection
import MemberwiseInit
import OrderedCollections
import SwiftDump
import Demangling
import Semantic
import SwiftStdlibToolbox
@_spi(Internals) import MachOSymbols
import Dependencies
import SwiftInspection

public final class ExtensionDefinition: Definition, MutableDefinition {
    public let extensionName: ExtensionName

    public let genericSignature: Node?

    public let protocolConformance: ProtocolConformance?

    public let associatedType: AssociatedType?

    @Mutex
    public var types: [TypeDefinition] = []

    @Mutex
    public var protocols: [ProtocolDefinition] = []

    @Mutex
    public var allocators: [FunctionDefinition] = []

    @Mutex
    public var constructors: [FunctionDefinition] = []

    @Mutex
    public var variables: [VariableDefinition] = []

    @Mutex
    public var functions: [FunctionDefinition] = []

    @Mutex
    public var subscripts: [SubscriptDefinition] = []

    @Mutex
    public var staticVariables: [VariableDefinition] = []

    @Mutex
    public var staticFunctions: [FunctionDefinition] = []

    @Mutex
    public var staticSubscripts: [SubscriptDefinition] = []

    @Mutex
    public var missingSymbolWitnesses: [ResilientWitness] = []

    @Mutex
    public private(set) var isIndexed: Bool = false

    public var hasMembers: Bool {
        !variables.isEmpty || !functions.isEmpty || !staticVariables.isEmpty || !staticFunctions.isEmpty || !allocators.isEmpty || !constructors.isEmpty || !staticSubscripts.isEmpty || !subscripts.isEmpty
    }

    public init<MachO: MachOSwiftSectionRepresentableWithCache>(extensionName: ExtensionName, genericSignature: Node?, protocolConformance: ProtocolConformance?, associatedType: AssociatedType?, in machO: MachO) throws {
        self.extensionName = extensionName
        self.genericSignature = genericSignature
        self.protocolConformance = protocolConformance
        self.associatedType = associatedType
    }

    package func index<MachO: MachOSwiftSectionRepresentableWithCache>(in machO: MachO) async throws {
        guard !isIndexed else { return }

        guard let protocolConformance, !protocolConformance.resilientWitnesses.isEmpty else {
            // Nothing to index, but mark as done so printing doesn't repeatedly call into `index`.
            isIndexed = true
            return
        }

        @Dependency(\.symbolIndexStore)
        var symbolIndexStore

        let targetTypeNode = extensionName.node
        let targetTypeName = extensionName.name
        let primitiveTypeName = PrimitiveTypeMappingCache.shared.storage(in: machO)?.primitiveType(for: targetTypeName)

        func _symbol(for symbols: Symbols, targetTypeName: String, primitiveTypeName: String?, visitedNodeIDs: borrowing Set<ObjectIdentifier> = []) throws -> DemangledSymbol? {
            for symbol in symbols {
                guard let node = symbolIndexStore.demangledNode(for: symbol, in: machO) else { continue }
                guard !visitedNodeIDs.contains(ObjectIdentifier(node)) else { continue }
                let protocolConformanceNode: Node
                if let firstChild = node.children.first, firstChild.kind == .protocolConformance {
                    protocolConformanceNode = firstChild
                } else if let found = node.first(of: .protocolConformance) {
                    protocolConformanceNode = found
                } else {
                    continue
                }
                guard let typeNode = protocolConformanceNode.children.first else { continue }
                if typeNode == targetTypeNode {
                    return .init(symbol: symbol, demangledNode: node)
                }
                let symbolTypeName = typeNode.print(using: .interfaceTypeBuilderOnly)
                if symbolTypeName == targetTypeName || primitiveTypeName == symbolTypeName {
                    return .init(symbol: symbol, demangledNode: node)
                }
            }
            return nil
        }
        var visitedNodeIDs: Set<ObjectIdentifier> = []
        var memberSymbolsByKind: OrderedDictionary<SymbolIndexStore.MemberKind, [DemangledSymbolWithOffset]> = [:]

        for resilientWitness in protocolConformance.resilientWitnesses {
            if let symbols = try resilientWitness.implementationSymbols(in: machO), let symbol = try _symbol(for: symbols, targetTypeName: targetTypeName, primitiveTypeName: primitiveTypeName, visitedNodeIDs: visitedNodeIDs) {
                visitedNodeIDs.insert(ObjectIdentifier(symbol.demangledNode))
                addSymbol(.init(symbol), memberSymbolsByKind: &memberSymbolsByKind, inExtension: true)
            } else if let requirement = try resilientWitness.requirement(in: machO) {
                switch requirement {
                case .symbol(let symbol):
                    if let demangledNode = symbolIndexStore.demangledNode(for: symbol, in: machO) {
                        addSymbol(.init(.init(symbol: symbol, demangledNode: demangledNode)), memberSymbolsByKind: &memberSymbolsByKind, inExtension: true)
                    }
                case .element(let element):
                    if let symbols = try await Symbols.resolve(from: element.offset, in: machO), let symbol = try _symbol(for: symbols, targetTypeName: targetTypeName, primitiveTypeName: primitiveTypeName, visitedNodeIDs: visitedNodeIDs) {
                        visitedNodeIDs.insert(ObjectIdentifier(symbol.demangledNode))
                        addSymbol(.init(symbol), memberSymbolsByKind: &memberSymbolsByKind, inExtension: true)
                    } else if let defaultImplementationSymbols = try element.defaultImplementationSymbols(in: machO), let symbol = try _symbol(for: defaultImplementationSymbols, targetTypeName: targetTypeName, primitiveTypeName: primitiveTypeName, visitedNodeIDs: visitedNodeIDs) {
                        visitedNodeIDs.insert(ObjectIdentifier(symbol.demangledNode))
                        addSymbol(.init(symbol), memberSymbolsByKind: &memberSymbolsByKind, inExtension: true)
                    } else if !element.defaultImplementation.isNull {
                        missingSymbolWitnesses.append(resilientWitness)
                    } else if !resilientWitness.implementation.isNull {
                        missingSymbolWitnesses.append(resilientWitness)
                    } else {
                        missingSymbolWitnesses.append(resilientWitness)
                    }
                }
            } else if !resilientWitness.implementation.isNull {
                missingSymbolWitnesses.append(resilientWitness)
            } else {
                missingSymbolWitnesses.append(resilientWitness)
            }
        }

        setDefinitions(for: memberSymbolsByKind, inExtension: true)

        isIndexed = true
    }
}
