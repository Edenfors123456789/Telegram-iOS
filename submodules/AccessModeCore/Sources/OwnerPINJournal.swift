import Foundation

/// Persisted only inside the authenticated encrypted vault. No PIN, unlocked
/// resource key or reusable user grant is part of this recovery operation.
struct PendingOwnerPINChange: Codable {
    static let maximumPlanBytes = 65_536
    let id: UUID
    let credentialID: UUID
    let configurationRevision: UInt64
    let replacement: PINCredential
    let preparedResources: Data

    func validate(state: AccessVaultState) throws {
        try replacement.validate(expectedMode: .a)
        guard credentialID == state.a.id, configurationRevision == state.configuration.revision,
              state.a.revision < UInt64.max, replacement.revision == state.a.revision + 1,
              replacement.id != state.a.id, replacement.id != state.b.id,
              replacement.salt != state.a.salt, replacement.salt != state.b.salt,
              !preparedResources.isEmpty, preparedResources.count <= Self.maximumPlanBytes else { throw AccessError.corrupt }
    }
}
