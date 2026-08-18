# Null Indirect Symbolic-Reference Resolution

## Motivation

Swift mangled names can encode an indirect context symbolic reference. The
relative reference points to a pointer-sized slot, and that slot may contain
zero when the referenced context is absent. The metadata reader represents
this ABI shape as
`RelativeIndirectSymbolOrElementPointer<ContextDescriptorWrapper?>`.

The optional spelling was already present in the type, but it was not honored
through generic pointer resolution. `SymbolOrElementPointer` supplied the
`RelativeIndirectType` conformance with unconditional `resolve` witnesses and
also declared optional-only overloads in a constrained extension. A direct
call on the concrete optional specialization selected the constrained
overload, while `RelativeIndirectPointerProtocol.resolveIndirect` invoked the
unconditional protocol witness. The latter converted address zero and asked a
reader to load an element there. For an in-process `MachOImage`, the conversion
produced an image-relative offset whose final pointer was exactly null, causing
SIGSEGV before `MetadataReader`'s error boundary could run.

## Ownership and invariant

`MachOSymbolPointers.SymbolOrElementPointer` owns interpretation of the value
stored in an indirect symbol-or-element slot. Neither a framework-specific
caller nor `MetadataReader` should duplicate that interpretation.

The invariant is:

> Every public element-resolution `resolve` overload on
> `SymbolOrElementPointer` observes a zero address before address conversion or
> element reads. If `Element` can represent absence, zero resolves to
> `.element(.none)`; otherwise resolution throws
> `ReadingError.invalidAddress(0)`.

The same unconditional `RelativeIndirectType` witnesses enforce the invariant
for context-free, `MachORepresentableWithCache`, and `ReadingContext` calls.
There is no constrained overload with different behavior, so direct and
generic dispatch cannot diverge.

## Design

The public generic type remains unchanged. The three public constrained
overload declarations are removed, but each of their call signatures remains
available through the unconditional conformance witness, so existing source
calls keep compiling when the package is rebuilt. Each unconditional witness
adds a zero-address case before the existing nonzero case. A private helper
checks whether `Element.Type` conforms to the existing `OptionalProtocol`,
obtains its `none` value through that checked existential, and casts the value
back to `Element`. The cast is checked rather than forced; failure and
genuinely non-optional elements use the existing
`ReadingError.invalidAddress(0)` error.

This approach is intentionally local:

- It does not add a public nullability protocol or a second pointer type.
- It does not change `RelativeIndirectPointerProtocol`; its generic dispatch is
  correct once the conformance witness owns the full contract.
- It does not add a `FoundationModels` or `MetadataReader` guard.
- Symbol resolution and every nonzero address path remain byte-for-byte the
  existing implementation.

The optional-only `SymbolOrElementPointer` extension is removed. Keeping it
would preserve two apparent sources of truth even if both happened to agree
today.

## Verification contract

Deterministic tests use synthetic storage and readers rather than system
framework fixtures:

1. `SymbolOrElementPointer.address(0)` resolves through the generic
   `RelativeIndirectType.resolve()` witness: optional elements produce
   `.element(nil)` and non-optional elements throw
   `ReadingError.invalidAddress(0)`.
2. The same value resolves through generic
   `RelativeIndirectType.resolve(in: MachO)`, with the same optional and
   non-optional results before image-relative conversion.
3. A nonzero relative pointer lands on a pointer-sized zero slot and resolves
   `RelativeIndirectSymbolOrElementPointer<ContextDescriptorWrapper?>` through
   the generic `RelativeIndirectPointerProtocol` route. The result is
   `.element(nil)`, and an instrumented reading context proves that no
   address-zero read or conversion occurred.
4. The same zero slot with a non-optional element throws
   `ReadingError.invalidAddress(0)` before a zero-address read.
5. A synthetic indirect context symbolic reference (`0x02`) is demangled
   through `MetadataReader` with an in-process `MachOImage`. The null slot is
   converted into the demangler's bounded
   `DemanglingError.requiredNonOptional` failure instead of terminating the
   process.

The tests live in regular assertion-bearing test targets. `IntegrationTests`
is neither used nor run.

## Compatibility and limitations

This is source-compatible: although the three constrained public declarations
are removed, the same call signatures remain available on the unconditional
witness, and this package is distributed from source. No binary ABI guarantee
is made. For non-optional zero slots, the previous behavior was an invalid
memory access; the new behavior is a typed read error. For optional zero slots,
the result now matches the constrained overload's documented intent.

The change does not attempt to recover a missing context descriptor. A null
symbolic reference remains unresolved, so the demangler reports its existing
parse error. Higher layers may surface that bounded failure according to their
existing per-declaration policy.
