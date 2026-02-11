import MachOSwiftSection
import Foundation
import Dispatch
import MemberwiseInit
import OrderedCollections
import SwiftDump
import Demangling
import Semantic
import SwiftStdlibToolbox
import MachOKit
import Dependencies
import Utilities
@_spi(Internals) import MachOSymbols
@_spi(Internals) import MachOCaches

public final class SwiftInterfaceBuilder<MachO: MachOSwiftSectionRepresentableWithCache>: Sendable {
    private struct UnsafeSendableBox<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) {
            self.value = value
        }
    }

    private static var internalModules: [String] {
        ["Swift", "_Concurrency", "_StringProcessing", "_SwiftConcurrencyShims"]
    }

    public let machO: MachO

    @_spi(Support)
    public let indexer: SwiftInterfaceIndexer<MachO>

    @_spi(Support)
    public let printer: SwiftInterfacePrinter<MachO>

    @Mutex
    public var configuration: SwiftInterfaceBuilderConfiguration = .init()

    @Mutex
    public private(set) var importedModules: OrderedSet<String> = []

    @Mutex
    public private(set) var extraDataProviders: [SwiftInterfaceBuilderExtraDataProvider] = []

    private let eventDispatcher: SwiftInterfaceEvents.Dispatcher
    private let hasEventHandlers: Bool

    /// Creates a new Swift interface builder for the given Mach-O binary.
    ///
    /// - Parameters:
    ///   - configuration: Configuration options for the builder. Defaults to a basic configuration.
    ///   - eventDispatcher: An event dispatcher for handling logging and progress events. A new one is created by default.
    ///   - machO: The Mach-O binary to analyze and generate interfaces from.
    /// - Throws: An error if the binary cannot be read or if required Swift sections are missing.
    public init(configuration: SwiftInterfaceBuilderConfiguration = .init(), eventHandlers: [SwiftInterfaceEvents.Handler] = [], in machO: MachO) throws {
        self.eventDispatcher = .init()
        self.hasEventHandlers = !eventHandlers.isEmpty
        self.machO = machO
        self.indexer = .init(configuration: configuration.indexConfiguration, eventHandlers: eventHandlers, in: machO)
        self.printer = .init(configuration: configuration.printConfiguration, eventHandlers: eventHandlers, in: machO)
        self.configuration = configuration
        eventDispatcher.addHandlers(eventHandlers)
    }

    public func addExtraDataProvider(_ extraDataProvider: some SwiftInterfaceBuilderExtraDataProvider) {
        extraDataProviders.append(extraDataProvider)
        printer.addTypeNameResolver(extraDataProvider)
    }

    public func removeAllExtraDataProviders() {
        extraDataProviders.removeAll()
        printer.removeAllTypeNameResolvers()
    }

    /// Prepares the builder by indexing all symbols and collecting module information.
    /// This is an asynchronous operation that must be called before generating interfaces.
    ///
    /// The preparation process includes:
    /// - Indexing all types, protocols, and extensions
    /// - Building cross-reference maps for conformances and associated types
    /// - Collecting all required module imports
    ///
    /// - Throws: An error if indexing fails or if required data cannot be extracted.
    public func prepare() async throws {
        eventDispatcher.dispatch(.phaseTransition(phase: .preparation, state: .started))

        for extraDataProvider in extraDataProviders {
            do {
                try await extraDataProvider.setup()
            } catch {
                print(error)
            }
        }

        do {
            try await indexer.prepare()
        } catch {
            eventDispatcher.dispatch(.phaseTransition(phase: .indexing, state: .failed(error)))
            throw error
        }

        do {
            try await collectModules()
        } catch {
            eventDispatcher.dispatch(.phaseTransition(phase: .moduleCollection, state: .failed(error)))
            throw error
        }

        eventDispatcher.dispatch(.phaseTransition(phase: .preparation, state: .completed))
    }

    @SemanticStringBuilder
    public func printRoot() async throws -> SemanticString {
        let buildStart = DispatchTime.now().uptimeNanoseconds
        let _ = hasEventHandlers ? eventDispatcher.dispatch(.phaseTransition(phase: .build, state: .started)) : ()

        ImportsBlock(OrderedSet(Self.internalModules + importedModules).sorted())

        let globalVariablesStart = DispatchTime.now().uptimeNanoseconds
        await printCatchedThrowing {
            await BlockList {
                for variable in indexer.globalVariableDefinitions {
                    await printer.printVariable(variable, level: 0)
                }
            }
        }
        let globalVariablesDuration = DispatchTime.now().uptimeNanoseconds &- globalVariablesStart
        let _ = hasEventHandlers ? eventDispatcher.dispatch(.diagnostic(message: .init(level: .debug, message: "build.globalVariables completed (\(formatDurationSeconds(globalVariablesDuration))) count=\(indexer.globalVariableDefinitions.count)", error: nil, context: nil))) : ()

        let globalFunctionsStart = DispatchTime.now().uptimeNanoseconds
        await printCatchedThrowing {
            await BlockList {
                for function in indexer.globalFunctionDefinitions {
                    await printer.printFunction(function)
                }
            }
        }
        let globalFunctionsDuration = DispatchTime.now().uptimeNanoseconds &- globalFunctionsStart
        let _ = hasEventHandlers ? eventDispatcher.dispatch(.diagnostic(message: .init(level: .debug, message: "build.globalFunctions completed (\(formatDurationSeconds(globalFunctionsDuration))) count=\(indexer.globalFunctionDefinitions.count)", error: nil, context: nil))) : ()

        let typesStart = DispatchTime.now().uptimeNanoseconds
        await printCatchedThrowing {
            try await BlockList {
                for typeDefinition in indexer.rootTypeDefinitions.values {
                    try await printer.printTypeDefinition(typeDefinition)
                }
            }
        }
        let typesDuration = DispatchTime.now().uptimeNanoseconds &- typesStart
        let _ = hasEventHandlers ? eventDispatcher.dispatch(.diagnostic(message: .init(level: .debug, message: "build.types completed (\(formatDurationSeconds(typesDuration))) count=\(indexer.rootTypeDefinitions.count)", error: nil, context: nil))) : ()

        let protocolsStart = DispatchTime.now().uptimeNanoseconds
        await printCatchedThrowing {
            try await BlockList {
                for protocolDefinition in indexer.rootProtocolDefinitions.values {
                    try await printer.printProtocolDefinition(protocolDefinition)
                }
            }
        }
        let protocolsDuration = DispatchTime.now().uptimeNanoseconds &- protocolsStart
        let _ = hasEventHandlers ? eventDispatcher.dispatch(.diagnostic(message: .init(level: .debug, message: "build.protocols completed (\(formatDurationSeconds(protocolsDuration))) count=\(indexer.rootProtocolDefinitions.count)", error: nil, context: nil))) : ()

        let defaultImplExtensionsStart = DispatchTime.now().uptimeNanoseconds
        await printCatchedThrowing {
            try await BlockList {
                for proto in indexer.rootProtocolDefinitions.values.filterNonNil(\.parent) {
                    for extensionDefinition in proto.defaultImplementationExtensions {
                        try await printer.printExtensionDefinition(extensionDefinition)
                    }
                }
            }
        }
        let defaultImplExtensionsDuration = DispatchTime.now().uptimeNanoseconds &- defaultImplExtensionsStart
        let _ = hasEventHandlers ? eventDispatcher.dispatch(.diagnostic(message: .init(level: .debug, message: "build.defaultImplementationExtensions completed (\(formatDurationSeconds(defaultImplExtensionsDuration)))", error: nil, context: nil))) : ()

        let extensionsStart = DispatchTime.now().uptimeNanoseconds
        await printCatchedThrowing {
            try await BlockList {
                // Preserve the existing output order without allocating an intermediate flattened array.
                var typeExtensionCount = 0
                let typeExtensionsStart = DispatchTime.now().uptimeNanoseconds
                for group in indexer.typeExtensionDefinitions.values {
                    for extensionDefinition in group {
                        typeExtensionCount += 1
                        try await printer.printExtensionDefinition(extensionDefinition)
                    }
                }
                let typeExtensionsDuration = DispatchTime.now().uptimeNanoseconds &- typeExtensionsStart
                let _ = hasEventHandlers ? eventDispatcher.dispatch(.diagnostic(message: .init(level: .debug, message: "build.extensions.type completed (\(formatDurationSeconds(typeExtensionsDuration))) count=\(typeExtensionCount)", error: nil, context: nil))) : ()

                var protocolExtensionCount = 0
                let protocolExtensionsStart = DispatchTime.now().uptimeNanoseconds
                for group in indexer.protocolExtensionDefinitions.values {
                    for extensionDefinition in group {
                        protocolExtensionCount += 1
                        try await printer.printExtensionDefinition(extensionDefinition)
                    }
                }
                let protocolExtensionsDuration = DispatchTime.now().uptimeNanoseconds &- protocolExtensionsStart
                let _ = hasEventHandlers ? eventDispatcher.dispatch(.diagnostic(message: .init(level: .debug, message: "build.extensions.protocol completed (\(formatDurationSeconds(protocolExtensionsDuration))) count=\(protocolExtensionCount)", error: nil, context: nil))) : ()

                var typeAliasExtensionCount = 0
                let typeAliasExtensionsStart = DispatchTime.now().uptimeNanoseconds
                for group in indexer.typeAliasExtensionDefinitions.values {
                    for extensionDefinition in group {
                        typeAliasExtensionCount += 1
                        try await printer.printExtensionDefinition(extensionDefinition)
                    }
                }
                let typeAliasExtensionsDuration = DispatchTime.now().uptimeNanoseconds &- typeAliasExtensionsStart
                let _ = hasEventHandlers ? eventDispatcher.dispatch(.diagnostic(message: .init(level: .debug, message: "build.extensions.typeAlias completed (\(formatDurationSeconds(typeAliasExtensionsDuration))) count=\(typeAliasExtensionCount)", error: nil, context: nil))) : ()

                var conformanceExtensions: [ExtensionDefinition] = []
                conformanceExtensions.reserveCapacity(indexer.conformanceExtensionDefinitions.values.reduce(into: 0) { $0 += $1.count })
                for group in indexer.conformanceExtensionDefinitions.values {
                    conformanceExtensions.append(contentsOf: group)
                }

                let conformanceExtensionCount = conformanceExtensions.count
                let conformanceExtensionsStart = DispatchTime.now().uptimeNanoseconds

                let conformanceIndexStart = DispatchTime.now().uptimeNanoseconds
                try await indexConformanceExtensions(conformanceExtensions)
                let conformanceIndexDuration = DispatchTime.now().uptimeNanoseconds &- conformanceIndexStart
                let _ = hasEventHandlers ? eventDispatcher.dispatch(.diagnostic(message: .init(level: .debug, message: "build.extensions.conformance.index completed (\(formatDurationSeconds(conformanceIndexDuration))) count=\(conformanceExtensionCount)", error: nil, context: nil))) : ()

                let conformancePrintStart = DispatchTime.now().uptimeNanoseconds
                for extensionDefinition in conformanceExtensions {
                    try await printer.printExtensionDefinition(extensionDefinition)
                }
                let conformancePrintDuration = DispatchTime.now().uptimeNanoseconds &- conformancePrintStart
                let _ = hasEventHandlers ? eventDispatcher.dispatch(.diagnostic(message: .init(level: .debug, message: "build.extensions.conformance.print completed (\(formatDurationSeconds(conformancePrintDuration))) count=\(conformanceExtensionCount)", error: nil, context: nil))) : ()

                let conformanceExtensionsDuration = DispatchTime.now().uptimeNanoseconds &- conformanceExtensionsStart
                let _ = hasEventHandlers ? eventDispatcher.dispatch(.diagnostic(message: .init(level: .debug, message: "build.extensions.conformance completed (\(formatDurationSeconds(conformanceExtensionsDuration))) count=\(conformanceExtensionCount)", error: nil, context: nil))) : ()
            }
        }

        let extensionsDuration = DispatchTime.now().uptimeNanoseconds &- extensionsStart
        let _ = hasEventHandlers ? eventDispatcher.dispatch(.diagnostic(message: .init(level: .debug, message: "build.extensions completed (\(formatDurationSeconds(extensionsDuration)))", error: nil, context: nil))) : ()

        let _ = hasEventHandlers ? eventDispatcher.dispatch(.phaseTransition(phase: .build, state: .completed)) : ()
        let buildDuration = DispatchTime.now().uptimeNanoseconds &- buildStart
        let _ = hasEventHandlers ? eventDispatcher.dispatch(.diagnostic(message: .init(level: .debug, message: "build.total completed (\(formatDurationSeconds(buildDuration)))", error: nil, context: nil))) : ()
    }

    private func collectModules() async throws {
        eventDispatcher.dispatch(.moduleCollectionStarted)
        @Dependency(\.symbolIndexStore)
        var symbolIndexStore

        var usedModules: OrderedSet<String> = []
        let filterModules: Set<String> = [cModule, objcModule, stdlibName]
        let allSymbols = symbolIndexStore.allSymbols(in: machO)

        eventDispatcher.dispatch(.symbolScanStarted(context: SwiftInterfaceEvents.SymbolScanContext(totalSymbols: allSymbols.count, filterModules: Array(filterModules.sorted()))))

        for symbol in allSymbols {
            for moduleNode in symbol.demangledNode.all(of: .module) {
                if let module = moduleNode.text, !filterModules.contains(module) {
                    if usedModules.append(module).inserted {
                        eventDispatcher.dispatch(.moduleFound(context: SwiftInterfaceEvents.ModuleContext(moduleName: module)))
                    }
                }
            }
        }

        importedModules = usedModules
        eventDispatcher.dispatch(.moduleCollectionCompleted(result: SwiftInterfaceEvents.ModuleCollectionResult(moduleCount: usedModules.count, modules: Array(usedModules.sorted()))))
    }

    private func formatDurationSeconds(_ nanos: UInt64) -> String {
        String(format: "%.3fs", Double(nanos) / 1_000_000_000.0)
    }

    private func indexConformanceExtensions(_ extensions: [ExtensionDefinition]) async throws {
        // Default to a conservative degree of parallelism. Conformance indexing is CPU heavy and benefits a lot
        // from parallelism, but it also touches shared caches.
        let maxConcurrent = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount))
        let machOBox = UnsafeSendableBox(machO)

        var iterator = extensions.makeIterator()
        try await withThrowingTaskGroup(of: Void.self) { group in
            var inFlight = 0
            while let ext = iterator.next() {
                let extBox = UnsafeSendableBox(ext)
                group.addTask {
                    if !extBox.value.isIndexed {
                        try await extBox.value.index(in: machOBox.value)
                    }
                }
                inFlight += 1
                if inFlight >= maxConcurrent {
                    _ = try await group.next()
                    inFlight -= 1
                }
            }

            while inFlight > 0 {
                _ = try await group.next()
                inFlight -= 1
            }
        }
    }
}
