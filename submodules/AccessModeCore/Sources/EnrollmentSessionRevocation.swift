import Foundation

/// A native verified auth.LoggedOut result for this exact original key/claim.
/// It is neither local-absence proof nor an unlock or display grant.
struct EnrollmentSessionRevocationRecord: Codable, Equatable {
    let claimID: UUID
    let sessionKey: AccountEnrollmentSessionKey
}
