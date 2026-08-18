import Foundation
import MachOKit
import Testing
@testable import Demangling
@testable import MachOSwiftSection
@testable @_spi(Internals) import SwiftInspection

@Suite("Null indirect symbolic references")
struct NullIndirectSymbolicReferenceTests {
    @Test("generic indirect resolution preserves optional null semantics")
    func genericIndirectResolutionPreservesOptionalNullSemantics() throws {
        let probe = AddressAccessProbe()
        let context = ZeroIndirectSlotContext(slotAddress: 108, probe: probe)
        let pointer = RelativeIndirectSymbolOrElementPointer<ContextDescriptorWrapper?>(relativeOffset: 8)

        let resolved = try resolveThroughProtocol(pointer, at: 100, in: context)

        if case .element(.none) = resolved {
            // Expected: the zero slot is represented by the optional element.
        } else {
            Issue.record("expected the zero slot to resolve as .element(nil), got \(resolved)")
        }
        #expect(probe.readAddresses == [108])
        #expect(probe.convertedVirtualAddresses.isEmpty)
    }

    @Test("generic indirect resolution rejects a nonoptional zero slot")
    func genericIndirectResolutionRejectsNonoptionalZeroSlot() {
        let probe = AddressAccessProbe()
        let context = ZeroIndirectSlotContext(slotAddress: 108, probe: probe)
        let pointer = RelativeIndirectSymbolOrElementPointer<ContextDescriptorWrapper>(relativeOffset: 8)

        do {
            _ = try resolveThroughProtocol(pointer, at: 100, in: context)
            Issue.record("expected ReadingError.invalidAddress(0)")
        } catch ReadingError.invalidAddress(let address) {
            #expect(address == 0)
        } catch {
            Issue.record("expected ReadingError.invalidAddress(0), got \(error)")
        }
        #expect(probe.readAddresses == [108])
        #expect(probe.convertedVirtualAddresses.isEmpty)
    }

    @Test("MetadataReader bounds a null kind-0x02 reference as a demangling error")
    func metadataReaderBoundsNullIndirectContextReference() {
        let slot = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        slot.initialize(to: 0)
        defer {
            slot.deinitialize(count: 1)
            slot.deallocate()
        }

        let machO = MachOImage.current()
        let slotOffset = Int(bitPattern: UnsafeRawPointer(slot)) &- Int(bitPattern: machO.ptr)
        let relativeOffset: RelativeOffset = 1
        let lookupOffset = slotOffset &- Int(relativeOffset)
        let mangledName = MangledName(
            elements: [
                .lookup(.init(
                    offset: lookupOffset,
                    reference: .relative(.init(kind: 0x02, relativeOffset: relativeOffset))
                )),
            ],
            startOffset: lookupOffset,
            endOffset: lookupOffset + 5
        )

        do {
            _ = try MetadataReader.demangleType(for: mangledName, in: machO)
            Issue.record("expected DemanglingError.requiredNonOptional")
        } catch DemanglingError.requiredNonOptional {
            // Expected: the symbolic-reference resolver returned nil.
        } catch {
            Issue.record("expected DemanglingError.requiredNonOptional, got \(error)")
        }
    }
}

private func resolveThroughProtocol<Pointer: RelativeIndirectPointerProtocol, Context: ReadingContext>(
    _ pointer: Pointer,
    at address: Context.Address,
    in context: Context
) throws -> Pointer.Pointee {
    try pointer.resolve(at: address, in: context)
}

private final class AddressAccessProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedReadAddresses: [Int] = []
    private var storedConvertedVirtualAddresses: [UInt64] = []

    var readAddresses: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return storedReadAddresses
    }

    var convertedVirtualAddresses: [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return storedConvertedVirtualAddresses
    }

    func recordRead(at address: Int) {
        lock.lock()
        storedReadAddresses.append(address)
        lock.unlock()
    }

    func recordConversion(of virtualAddress: UInt64) {
        lock.lock()
        storedConvertedVirtualAddresses.append(virtualAddress)
        lock.unlock()
    }
}

private struct ZeroIndirectSlotContext: ReadingContext {
    typealias Runtime = RuntimeTarget64
    typealias Address = Int

    let slotAddress: Int
    let probe: AddressAccessProbe

    func readElement<T>(at address: Int) throws -> T {
        probe.recordRead(at: address)
        guard address == slotAddress, let zero = UInt64.zero as? T else {
            throw ReadingError.invalidAddress(address)
        }
        return zero
    }

    func readElements<T>(at address: Int, numberOfElements: Int) throws -> [T] {
        probe.recordRead(at: address)
        throw ReadingError.invalidAddress(address)
    }

    func readWrapperElement<T: LocatableLayoutWrapper>(at address: Int) throws -> T {
        probe.recordRead(at: address)
        throw ReadingError.invalidAddress(address)
    }

    func readWrapperElements<T: LocatableLayoutWrapper>(at address: Int, numberOfElements: Int) throws -> [T] {
        probe.recordRead(at: address)
        throw ReadingError.invalidAddress(address)
    }

    func readString(at address: Int) throws -> String {
        probe.recordRead(at: address)
        throw ReadingError.invalidAddress(address)
    }

    func advanceAddress(_ address: Int, by delta: Int) -> Int {
        address + delta
    }

    func advanceAddress<T>(_ address: Int, of type: T.Type) -> Int {
        address + MemoryLayout<T>.size
    }

    func addressFromOffset(_ offset: Int) throws -> Int {
        offset
    }

    func addressFromVirtualAddress(_ virtualAddress: UInt64) throws -> Int {
        probe.recordConversion(of: virtualAddress)
        guard virtualAddress != 0 else {
            throw ReadingError.invalidAddress(0)
        }
        return numericCast(virtualAddress)
    }

    func offsetFromAddress(_ address: Int) throws -> Int {
        address
    }
}
