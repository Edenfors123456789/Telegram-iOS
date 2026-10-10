import Foundation

/// SHA-256 of an existing persistent key; never stores the authorization key.
public struct AccountEnrollmentSessionKey: Codable, Equatable {
    public let datacenterID: Int32
    public let digest: Data
    public init(datacenterID: Int32, digest: Data) throws {
        guard datacenterID > 0, digest.count == 32 else { throw AccessError.invalidConfiguration }
        self.datacenterID = datacenterID; self.digest = digest
    }
    var isValid: Bool { datacenterID > 0 && digest.count == 32 }
}
