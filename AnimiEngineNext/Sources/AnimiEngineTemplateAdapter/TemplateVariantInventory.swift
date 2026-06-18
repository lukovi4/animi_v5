/// Task-003 plan §17 step 6 — the **variant inventory** built from a decoded compiled template.
///
/// This is the first conversion-adjacent value produced by the adapter, but it is **not** canonical
/// conversion (§17 step 7, deliberately deferred). It is a pure, immutable, `Sendable`,
/// deterministic projection of `DecodedCompiledTemplate` that captures exactly *which* authored
/// blocks and variants exist, in their authored order, plus the producer's selection/edit pointers.
///
/// Properties enforced by construction:
///   * authored scene block order is preserved (the runtime `blocks` array is the producer's
///     faithful, order-preserving derivation of the scene `mediaBlocks` array — proven by the
///     decoder's `orderIndex == sceneIndex` and the block-id bijection);
///   * each block carries its `blockID`, `orderIndex`, `selectedVariantID` and `editVariantID`;
///   * every authored variant appears exactly once, with its `variantID` and `animRef`, in authored
///     order.
///
/// Production code here performs **no** filesystem IO: the inventory is a value transform over an
/// already-decoded structure. Repeated construction from the same `DecodedCompiledTemplate` is
/// value-identical (`Equatable`), because the inventory only copies already-validated, ordered DTO
/// fields with no clocks, randomness, set iteration or dictionary ordering involved.

// MARK: - Inventory value

/// An immutable, deterministic inventory of the authored blocks and variants of a compiled template.
public struct TemplateVariantInventory: Equatable, Sendable {
    /// Authored blocks in authored scene order (index 0 == first authored block).
    public let blocks: [Block]

    /// One authored block and its authored variants.
    public struct Block: Equatable, Sendable {
        /// The block's stable id (producer `blockId`).
        public let blockID: String
        /// The authored position of this block (producer `orderIndex`), equal to the block's index
        /// in `blocks`.
        public let orderIndex: Int
        /// The producer's selected variant id (the first authored scene variant).
        public let selectedVariantID: String
        /// The producer's edit variant id (`no-anim`).
        public let editVariantID: String
        /// Authored variants in authored order; each appears exactly once.
        public let variants: [Variant]

        /// Package-internal raw initializer. Deliberately **not** `public`: external callers must go
        /// through `TemplateVariantInventory(from:)` so they cannot fabricate an inventory whose
        /// block order, `orderIndex` or variant set contradicts a real compiled template. `@testable`
        /// imports may still build golden values with it.
        init(
            blockID: String,
            orderIndex: Int,
            selectedVariantID: String,
            editVariantID: String,
            variants: [Variant]
        ) {
            self.blockID = blockID
            self.orderIndex = orderIndex
            self.selectedVariantID = selectedVariantID
            self.editVariantID = editVariantID
            self.variants = variants
        }
    }

    /// One authored variant.
    public struct Variant: Equatable, Sendable {
        /// The variant's stable id (producer `variantId`).
        public let variantID: String
        /// The variant's animation reference (producer `animRef`).
        public let animRef: String

        /// Package-internal raw initializer (see `Block.init` for the rationale).
        init(variantID: String, animRef: String) {
            self.variantID = variantID
            self.animRef = animRef
        }
    }

    /// Package-internal raw initializer. Not `public` — external callers must use
    /// `TemplateVariantInventory(from:)`; `@testable` tests use it to build golden values.
    init(blocks: [Block]) {
        self.blocks = blocks
    }

    // MARK: - Construction from a decoded template

    /// Builds the inventory from a decoded compiled template, strictly in **authored scene order**.
    ///
    /// `SceneCompiler` sorts `runtime.blocks` by `(zIndex, orderIndex)`, so the runtime `blocks`
    /// array order is **not** authored order and must never be used as such. The authored order is
    /// `runtime.scene.mediaBlocks` (and, within a block, `mediaBlocks[].variants`). Each authored
    /// scene block is matched to its runtime block by `blockID` to read the producer-derived
    /// `selectedVariantID`/`editVariantID`/`orderIndex`.
    ///
    /// A correctly decoded template has already had the block-id bijection proven by the decoder, so
    /// every lookup below resolves; this initializer nonetheless resolves each runtime block with an
    /// explicit `guard` and **throws** a typed error rather than substituting any fallback value
    /// (no `??`, force-unwrap, `precondition` or trap). The result is a pure, deterministic
    /// projection with no IO.
    public init(from decoded: DecodedCompiledTemplate) throws {
        let runtime = decoded.payload.compiled.runtime
        let runtimeByID = Dictionary(uniqueKeysWithValues: runtime.blocks.map { ($0.blockID, $0) })

        var blocks: [Block] = []
        blocks.reserveCapacity(runtime.scene.mediaBlocks.count)
        for sceneBlock in runtime.scene.mediaBlocks {
            // The matched runtime block carries the producer-derived selection/edit pointers and
            // `orderIndex`. A missing match is a malformed package, not a recoverable default.
            guard let runtimeBlock = runtimeByID[sceneBlock.blockID] else {
                throw TemplateInventoryConstructionError.missingRuntimeBlock(blockID: sceneBlock.blockID)
            }
            blocks.append(Block(
                blockID: sceneBlock.blockID,
                orderIndex: runtimeBlock.orderIndex,
                selectedVariantID: runtimeBlock.selectedVariantID,
                editVariantID: runtimeBlock.editVariantID,
                // Authored variant order comes from the scene block, not the runtime block.
                variants: sceneBlock.variants.map { Variant(variantID: $0.variantID, animRef: $0.animRef) }
            ))
        }
        self.init(blocks: blocks)
    }

    // MARK: - Strict explicit-selection validation

    /// An explicit, fully-specified variant selection: exactly one chosen variant per block.
    ///
    /// There is **no** implicit default, first-variant or selected-variant fallback. A caller must
    /// name a variant for every block; under- or over-specification is a typed error.
    public struct Selection: Equatable, Sendable {
        /// Chosen variant id keyed by block id.
        public let chosenVariantByBlockID: [String: String]

        public init(chosenVariantByBlockID: [String: String]) {
            self.chosenVariantByBlockID = chosenVariantByBlockID
        }
    }

    /// Validates an explicit selection against this inventory.
    ///
    /// Rules (all fail-closed, no fallback):
    ///   * every block must have exactly one selection — a block absent from the selection is a
    ///     `missingBlockSelection`;
    ///   * a selection key that is not an authored block is an `unknownBlock`;
    ///   * a chosen variant that is not authored for that block is an `unknownVariant`.
    ///
    /// On success, returns the selection unchanged (it is fully resolved by definition).
    @discardableResult
    public func validate(selection: Selection) throws -> Selection {
        let blockIDs = Set(blocks.map(\.blockID))

        // Unknown selection keys (a key naming a block this inventory does not contain). Reported
        // deterministically in sorted order.
        let unknownBlockKeys = Set(selection.chosenVariantByBlockID.keys).subtracting(blockIDs)
        if let unknown = unknownBlockKeys.sorted().first {
            throw TemplateVariantSelectionError.unknownBlock(blockID: unknown)
        }

        // Each authored block, in authored order, must be selected with an authored variant.
        for block in blocks {
            guard let chosen = selection.chosenVariantByBlockID[block.blockID] else {
                throw TemplateVariantSelectionError.missingBlockSelection(blockID: block.blockID)
            }
            guard block.variants.contains(where: { $0.variantID == chosen }) else {
                throw TemplateVariantSelectionError.unknownVariant(blockID: block.blockID, variantID: chosen)
            }
        }

        return selection
    }
}

// MARK: - Typed construction errors

/// Typed errors raised while building a ``TemplateVariantInventory`` from a decoded template.
///
/// A correctly decoded package never triggers these (the decoder proves the scene↔runtime block
/// bijection), but the inventory still resolves each runtime block explicitly and fails closed on a
/// malformed decoded value rather than substituting any default (§9 prohibitions).
public enum TemplateInventoryConstructionError: Error, Equatable, Sendable {
    /// An authored scene block had no matching runtime block by `blockID`.
    case missingRuntimeBlock(blockID: String)
}

// MARK: - Typed selection errors

/// Typed errors for explicit variant selection against a ``TemplateVariantInventory``.
///
/// These are conversion-domain errors (the inventory is the conversion entry point), kept as a
/// dedicated, self-contained enum so step 6 introduces no premature canonical-conversion surface
/// (§17 step 7 remains deferred). No layer substitutes a default or first variant (§9 prohibitions).
public enum TemplateVariantSelectionError: Error, Equatable, Sendable {
    /// A block authored in the inventory had no entry in the selection.
    case missingBlockSelection(blockID: String)
    /// The selection named a block that is not authored in the inventory.
    case unknownBlock(blockID: String)
    /// The selection chose a variant that is not authored for that block.
    case unknownVariant(blockID: String, variantID: String)
}
