import Foundation
import Testing
import MachOKit
import MachOFoundation
@testable import MachOSwiftSection
import SwiftDeclarationRendering

private struct LayoutAccessorStruct {
    var value: Int
}

private final class LayoutAccessorClass {
    var value: Int = 0
}

private enum LayoutAccessorEnum {
    case value(Int)
    case empty
}

private enum AccessorProbe {
    nonisolated(unsafe) static var calls = 0
    nonisolated(unsafe) static var metadataPointer: UnsafeRawPointer!
}

// The accessor ABI returns two scalar words. Using scalar parameters/results
// avoids the indirect ABI of non-frozen Swift structs across module boundaries.
@_silgen_name("field_layout_counting_metadata_accessor")
@inline(never)
public func countingMetadataAccessor(_ request: Int) -> (UnsafeRawPointer, Int) {
    AccessorProbe.calls += 1
    return (AccessorProbe.metadataPointer, 0)
}

@Suite(.serialized)
struct FieldLayoutAccessorResolutionTests {
    private static let fixtureNames = ["LayoutAccessorStruct", "LayoutAccessorClass", "LayoutAccessorEnum"]

    @MainActor
    private func fixture(named name: String) throws -> (type: TypeContextWrapper, metadata: MetadataWrapper, machO: MachOImage) {
        let metatype: Any.Type
        switch name {
        case "LayoutAccessorStruct": metatype = LayoutAccessorStruct.self
        case "LayoutAccessorClass": metatype = LayoutAccessorClass.self
        default: metatype = LayoutAccessorEnum.self
        }
        let machO = MachOImage.current()
        AccessorProbe.metadataPointer = unsafeBitCast(metatype, to: UnsafeRawPointer.self)
        _ = countingMetadataAccessor(0)
        AccessorProbe.calls = 0
        let metadata = try Pointer<MetadataWrapper>(address: UInt64(UInt(bitPattern: AccessorProbe.metadataPointer))).resolve(in: machO)
        let type = try #require(try machO.swift.types.first { type in
            switch type {
            case .struct(let value): return try value.descriptor.name(in: machO) == name
            case .class(let value): return try value.descriptor.name(in: machO) == name
            case .enum(let value): return try value.descriptor.name(in: machO) == name
            }
        })

        // Only the parsed wrapper changes; the image's read-only descriptor and
        // the compiler-generated metadata remain intact.
        let countingType: TypeContextWrapper
        switch type {
        case .struct(let value):
            let descriptor = value.descriptor
            let layout = descriptor.layout
            let countingDescriptor = StructDescriptor(layout: .init(
                flags: layout.flags, parent: layout.parent, name: layout.name,
                accessFunctionPtr: try accessorPointer(for: descriptor, in: machO),
                fieldDescriptor: layout.fieldDescriptor, numFields: layout.numFields, fieldOffsetVector: layout.fieldOffsetVector
            ), offset: descriptor.offset)
            countingType = .struct(try Struct(descriptor: countingDescriptor, in: machO))
        case .class(let value):
            let descriptor = value.descriptor
            let layout = descriptor.layout
            let countingDescriptor = ClassDescriptor(layout: .init(
                flags: layout.flags, parent: layout.parent, name: layout.name,
                accessFunctionPtr: try accessorPointer(for: descriptor, in: machO), fieldDescriptor: layout.fieldDescriptor,
                superclassType: layout.superclassType,
                metadataNegativeSizeInWordsOrResilientMetadataBounds: layout.metadataNegativeSizeInWordsOrResilientMetadataBounds,
                metadataPositiveSizeInWordsOrExtraClassFlags: layout.metadataPositiveSizeInWordsOrExtraClassFlags,
                numImmediateMembers: layout.numImmediateMembers, numFields: layout.numFields,
                fieldOffsetVectorOffset: layout.fieldOffsetVectorOffset
            ), offset: descriptor.offset)
            countingType = .class(try Class(descriptor: countingDescriptor, in: machO))
        case .enum(let value):
            let descriptor = value.descriptor
            let layout = descriptor.layout
            let countingDescriptor = EnumDescriptor(layout: .init(
                flags: layout.flags, parent: layout.parent, name: layout.name,
                accessFunctionPtr: try accessorPointer(for: descriptor, in: machO), fieldDescriptor: layout.fieldDescriptor,
                numPayloadCasesAndPayloadSizeOffset: layout.numPayloadCasesAndPayloadSizeOffset, numEmptyCases: layout.numEmptyCases
            ), offset: descriptor.offset)
            countingType = .enum(try Enum(descriptor: countingDescriptor, in: machO))
        }
        return (countingType, metadata, machO)
    }

    private func accessorPointer<Descriptor: TypeContextDescriptorProtocol>(for descriptor: Descriptor, in machO: MachOImage) throws -> RelativeDirectPointer<MetadataAccessorFunction> {
        let accessorSymbol = try #require(machO.symbols.first { $0.name == "_field_layout_counting_metadata_accessor" })
        let accessorPointer = machO.ptr + accessorSymbol.offset
        let slotOffset = descriptor.layout.offset(of: .accessFunctionPtr)
        let slotPointer = machO.ptr + descriptor.offset + slotOffset
        let relativeOffset = try #require(Int32(exactly: Int(bitPattern: accessorPointer) - Int(bitPattern: slotPointer)))
        return .init(relativeOffset: relativeOffset)
    }

    @MainActor
    @Test(arguments: Self.fixtureNames)
    func declarationsDoNotCallMetadataAccessor(name: String) throws {
        let fixture = try fixture(named: name)
        let configuration = DeclarationRenderConfiguration.demangleOptions(.default)
        let renderer = FieldLayoutRenderer(type: fixture.type, metadata: nil, machO: fixture.machO, configuration: configuration)

        #expect(AccessorProbe.calls == 0)
        #expect(renderer.metadata == nil)
        #expect(renderer.fieldOffsets == nil)
    }

    @MainActor
    @Test(arguments: Self.fixtureNames)
    func unrelatedLayoutOptionsDoNotCallParentAccessor(name: String) async throws {
        let fixture = try fixture(named: name)
        var configuration = DeclarationRenderConfiguration.demangleOptions(.default)
        configuration.printTypeLayout = true
        configuration.printExpandedFieldOffsets = true
        configuration.printSpareBitAnalysis = true
        configuration.printVTableOffset = true
        configuration.printFieldOffset = name == "LayoutAccessorEnum"
        configuration.printEnumLayout = name != "LayoutAccessorEnum"
        let renderer = FieldLayoutRenderer(type: fixture.type, metadata: nil, machO: fixture.machO, configuration: configuration)

        #expect(AccessorProbe.calls == 0)
        #expect(renderer.metadata == nil)
        let descriptor = try #require(fixture.type.contextDescriptorWrapper.typeContextDescriptor)
        let records = try descriptor.fieldDescriptor(in: fixture.machO).records(in: fixture.machO)
        let firstRecord = try #require(records.first)
        #expect(try firstRecord.fieldName(in: fixture.machO) == "value")
        let mangledName = try firstRecord.mangledTypeName(in: fixture.machO)
        let comments: String
        if case .enum = fixture.type {
            comments = try await renderer.enumCaseComments(forCaseAtIndex: 0, mangledTypeName: mangledName, enumLayout: await renderer.enumLayout).string
        } else {
            comments = try await renderer.storedFieldComments(forFieldAtIndex: 0, mangledTypeName: mangledName, fieldOffsets: renderer.fieldOffsets).string
        }
        #expect(comments.contains("Type Layout"))
        #expect(AccessorProbe.calls == 0)
    }

    @MainActor
    @Test(arguments: Self.fixtureNames)
    func requestedLayoutResolvesMetadata(name: String) async throws {
        let fixture = try fixture(named: name)
        var configuration = DeclarationRenderConfiguration.demangleOptions(.default)
        if case .enum = fixture.type {
            configuration.printEnumLayout = true
        } else {
            configuration.printFieldOffset = true
        }
        let renderer = FieldLayoutRenderer(type: fixture.type, metadata: nil, machO: fixture.machO, configuration: configuration)

        #expect(AccessorProbe.calls == 1)
        #expect(renderer.metadata?.anyMetadata.offset == fixture.metadata.anyMetadata.offset)
        if case .enum = fixture.type {
            let layout = try #require(await renderer.enumLayout)
            #expect(layout.cases.count == 2)
        } else {
            let offsets = try #require(renderer.fieldOffsets)
            #expect(offsets.count == 1)
        }
    }

    @MainActor
    @Test(arguments: Self.fixtureNames)
    func suppliedMetadataIsRetainedAndAutoResolutionCanBeDisabled(name: String) throws {
        let fixture = try fixture(named: name)
        var configuration = DeclarationRenderConfiguration.demangleOptions(.default)
        let supplied = FieldLayoutRenderer(type: fixture.type, metadata: fixture.metadata, machO: fixture.machO, configuration: configuration)
        #expect(supplied.metadata?.anyMetadata.offset == fixture.metadata.anyMetadata.offset)

        configuration.printFieldOffset = true
        configuration.printEnumLayout = true
        let disabled = FieldLayoutRenderer(type: fixture.type, metadata: nil, machO: fixture.machO, configuration: configuration, autoResolveAccessorMetadata: false)
        #expect(disabled.metadata == nil)
        #expect(AccessorProbe.calls == 0)
    }
}
