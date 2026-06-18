import Foundation
import AnimiEngineCore
import AnimiEngineRenderModel
import AnimiEngineMetalRender
import AnimiEngineDiagnostics
import AnimiEngineNext

/// Task-003 / Step-14 — drives the complete real-template/frame matrix + structural fixtures through the
/// Step-13 evidence recorder, into ONE `BenchmarkRun`, grouped (per catalog + one structural group, D1).
///
/// Determinism + transactional guarantees are inherited from the Step-13 recorder/run. The driver enforces
/// GLOBAL candidate-id uniqueness across the whole matrix (constraint 7: a collision is a typed STOP error),
/// uses the `ReferenceStore` strictly READ-ONLY (no promotion, no approved-root write), and closes the run
/// exactly once after the last group.
public struct MatrixDriver: Sendable {

    public enum DriverError: Error, Equatable, Sendable {
        case duplicateCandidateID(String)        // STOP: two distinct rows collide on candidate id
    }

    /// The outcome of a matrix run (for test assertions).
    public struct Result: Sendable {
        public let enumeratedRowCount: Int        // total rows enumerated (real)
        public let realRowCount: Int              // real rows that rendered + recorded
        public let skippedRowCount: Int           // rows deterministically skipped (authored-timing inactivity)
        public let structuralRowCount: Int
        public let candidateCount: Int            // == realRowCount + structuralRowCount (unique)
        public let groupManifests: [String: RenderEvidenceManifest]   // group → its render manifest
        public let runDirectoryURL: URL
    }

    public let scenesRootURL: URL
    public let referenceStore: ReferenceStore?
    public let configuration: RenderConfiguration
    public let policy: EvidenceRecorder.Policy

    public init(scenesRootURL: URL, referenceStore: ReferenceStore?, configuration: RenderConfiguration, policy: EvidenceRecorder.Policy) {
        self.scenesRootURL = scenesRootURL
        self.referenceStore = referenceStore
        self.configuration = configuration
        self.policy = policy
    }

    /// Run the full matrix: real rows grouped per catalog, structural fixtures as one group, all into `run`.
    /// Closes `run` once at the end (status .success — D3: outOfBounds is record-only, never gates).
    public func run(
        session: MetalRenderSession, into run: BenchmarkRun,
        engineConfiguration: EngineConfiguration, deviceInfo: DeviceInfo
    ) throws -> Result {
        let recorder = EvidenceRecorder()
        var globalIDs = Set<String>()
        var groupManifests: [String: RenderEvidenceManifest] = [:]

        // 1) Real rows, grouped by catalog (deterministic order).
        let rows = try RealTemplateMatrix.enumerateRows(scenesRootURL: scenesRootURL)
        var realCount = 0, skippedCount = 0
        for catalogID in RealTemplateMatrix.catalogs {
            let catalogRows = rows.filter { $0.catalogID == catalogID }
            var candidates: [CandidateFrame] = []
            for row in catalogRows {
                switch try RealTemplateMatrix.compileOutcome(row: row, scenesRootURL: scenesRootURL, configuration: configuration) {
                case .skippedInactive:
                    skippedCount += 1   // authored-timing inactivity: deterministically excluded, not recorded
                case .renderable(let compiled):
                    let candidate = try CandidateGenerator.generate(
                        graph: compiled.graph, session: session,
                        catalogID: row.catalogID, blockID: row.blockID, variantID: "\(row.variantID)-\(row.frameKind)",
                        projectTimeTicks: row.projectTimeTicks, configHash: compiled.configHash)
                    try requireUniqueGlobal(candidate.candidateID, &globalIDs)
                    candidates.append(candidate)
                }
            }
            realCount += candidates.count
            // A catalog with at least one renderable row records a group; an all-skipped catalog (none in
            // practice — tick0 is always renderable) would have an empty group, which the recorder rejects.
            if !candidates.isEmpty {
                let manifest = try recorder.recordGroup(
                    group: catalogID, candidates: candidates, referenceStore: referenceStore, policy: policy,
                    into: run, engineConfiguration: engineConfiguration, deviceInfo: deviceInfo)
                groupManifests[catalogID] = manifest
            }
        }

        // 2) Structural fixtures as one group.
        let fixtures = try StructuralFixtures.all()
        var structuralCandidates: [CandidateFrame] = []
        for fixture in fixtures {
            let candidate = try CandidateGenerator.generate(
                graph: fixture.graph, session: session,
                catalogID: fixture.catalogID, blockID: fixture.blockID, variantID: fixture.variantID,
                projectTimeTicks: fixture.projectTimeTicks, configHash: try fixture.graph.graphHash())
            try requireUniqueGlobal(candidate.candidateID, &globalIDs)
            structuralCandidates.append(candidate)
        }
        let structuralManifest = try recorder.recordGroup(
            group: "structural", candidates: structuralCandidates, referenceStore: referenceStore, policy: policy,
            into: run, engineConfiguration: engineConfiguration, deviceInfo: deviceInfo)
        groupManifests["structural"] = structuralManifest

        // 3) Close the run ONCE (manifest-last). D3: record-only, status success.
        try run.close(engineConfiguration: engineConfiguration, deviceInfo: deviceInfo, status: .success)

        return Result(
            enumeratedRowCount: rows.count, realRowCount: realCount, skippedRowCount: skippedCount,
            structuralRowCount: structuralCandidates.count,
            candidateCount: globalIDs.count, groupManifests: groupManifests, runDirectoryURL: run.directoryURL)
    }

    private func requireUniqueGlobal(_ id: String, _ seen: inout Set<String>) throws {
        guard seen.insert(id).inserted else { throw DriverError.duplicateCandidateID(id) }
    }
}
