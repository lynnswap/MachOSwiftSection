@_spi(Internals) import MachOSymbols
import OrderedCollections

extension Definition {
    func addSymbol(_ symbol: DemangledSymbolWithOffset, memberSymbolsByKind: inout OrderedDictionary<SymbolIndexStore.MemberKind, [DemangledSymbolWithOffset]>, inExtension: Bool) {
        let node = symbol.demangledNode

        // `Node.contains(...)` performs a preorder walk each time, so keep this classification to a single pass.
        var hasVariable = false
        var hasAllocator = false
        var hasFunction = false
        var hasSubscript = false
        var hasStatic = false
        var isStoredVariable = false

        for child in node {
            switch child.kind {
            case .static:
                hasStatic = true
            case .variable:
                // Mirror `first(of: .variable)` semantics used by `node.isStoredVariable`.
                if !hasVariable {
                    hasVariable = true
                    isStoredVariable = child.parent?.isAccessor == false
                }
            case .allocator:
                hasAllocator = true
            case .function:
                hasFunction = true
            case .subscript:
                hasSubscript = true
            default:
                break
            }
        }

        if hasVariable {
            if hasStatic {
                memberSymbolsByKind[.variable(inExtension: inExtension, isStatic: true, isStorage: isStoredVariable), default: []].append(symbol)
            } else {
                memberSymbolsByKind[.variable(inExtension: inExtension, isStatic: false, isStorage: false), default: []].append(symbol)
            }
        } else if hasAllocator {
            memberSymbolsByKind[.allocator(inExtension: inExtension), default: []].append(symbol)
        } else if hasFunction {
            memberSymbolsByKind[.function(inExtension: inExtension, isStatic: hasStatic), default: []].append(symbol)
        } else if hasSubscript {
            memberSymbolsByKind[.subscript(inExtension: inExtension, isStatic: hasStatic), default: []].append(symbol)
        }
    }
}

extension MutableDefinition {
    func setDefinitions(for memberSymbolsByKind: OrderedDictionary<SymbolIndexStore.MemberKind, [DemangledSymbolWithOffset]>, inExtension: Bool) {
        for (kind, memberSymbols) in memberSymbolsByKind {
            switch kind {
            case .variable(inExtension, let isStatic, false):
                if isStatic {
                    staticVariables = DefinitionBuilder.variables(for: memberSymbols, fieldNames: [], isGlobalOrStatic: true)
                } else {
                    variables = DefinitionBuilder.variables(for: memberSymbols, fieldNames: [], isGlobalOrStatic: false)
                }
            case .allocator:
                allocators = DefinitionBuilder.allocators(for: memberSymbols)
            case .function(inExtension, let isStatic):
                if isStatic {
                    staticFunctions = DefinitionBuilder.functions(for: memberSymbols, isGlobalOrStatic: true)
                } else {
                    functions = DefinitionBuilder.functions(for: memberSymbols, isGlobalOrStatic: false)
                }
            case .subscript(inExtension, let isStatic):
                if isStatic {
                    staticSubscripts = DefinitionBuilder.subscripts(for: memberSymbols, isStatic: true)
                } else {
                    subscripts = DefinitionBuilder.subscripts(for: memberSymbols, isStatic: false)
                }
            default:
                break
            }
        }
    }
}
