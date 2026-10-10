import XCTest
@testable import AccessModeCore

final class ChatIdentityTests: XCTestCase {
    private let account = AccountIdentity(installation: UUID(), environment: .production, recordID: -27, userID: 101)

    private func chat(_ namespace: Int32, _ id: Int64) -> ChatIdentity {
        ChatIdentity(account: account, peerNamespace: namespace, peerID: id)
    }

    func testSecretChatUsesTheSignedInt32DomainWithoutChangingItsSign() {
        // Telegram's API encrypted-chat ID is signed Int32. Postbox explicitly
        // decodes namespace 3 through Int32(bitPattern:), rather than abs(id).
        for id in [Int64(Int32.min), -42, -1, 1, 42, Int64(Int32.max)] {
            let identity = chat(3, id)
            XCTAssertTrue(identity.supported, "Valid signed secret ID was denied: \(id)")
            XCTAssertEqual(identity.peerID, id)
        }
        for id in [Int64.min, Int64(Int32.min) - 1, 0, Int64(Int32.max) + 1, Int64.max] {
            XCTAssertFalse(chat(3, id).supported, "Invalid secret ID was accepted: \(id)")
        }
    }

    func testCloudAndUnknownNamespacesDoNotAdoptNegativeSecretAliases() {
        for namespace: Int32 in 0 ... 2 {
            XCTAssertTrue(chat(namespace, 42).supported)
            XCTAssertFalse(chat(namespace, -42).supported)
            XCTAssertFalse(chat(namespace, 0).supported)
        }
        for namespace: Int32 in [-1, 4, 7, 42] {
            XCTAssertFalse(chat(namespace, 42).supported)
            XCTAssertFalse(chat(namespace, -42).supported)
        }
        XCTAssertEqual(Set([chat(3, -42), chat(3, 42), chat(0, 42)]).count, 3)
    }

    func testSignedHiddenChatConfigurationRoundTripKeepsDistinctNamespaceAndSign() throws {
        let hidden: Set<ChatIdentity> = [chat(3, -42), chat(3, 42), chat(0, 42)]
        let configuration: AccessConfiguration
        do {
            configuration = try AccessConfiguration(installation: account.installation,
                accounts: [AccountMembership(identity: account, ownership: .shared)],
                hiddenChats: hidden, selectedA: account, selectedB: account)
        } catch { XCTFail("Valid signed secret configuration refused: \(error)"); return }
        let decoded = try JSONDecoder().decode(AccessConfiguration.self, from: JSONEncoder().encode(configuration))
        try decoded.validate()
        XCTAssertEqual(decoded, configuration)
        XCTAssertEqual(decoded.hiddenChats, hidden)
        let a = AccessModePolicy(mode: .a, configuration: decoded)
        let b = AccessModePolicy(mode: .b, configuration: decoded)
        for identity in hidden {
            XCTAssertTrue(a.isMarkedHidden(identity)); XCTAssertTrue(a.discover(identity))
            XCTAssertFalse(b.discover(identity)); XCTAssertEqual(b.explicitOpen(identity), .restrictedTranscript)
        }
        XCTAssertEqual(a.hiddenChatsForManagement.count, 3)
        XCTAssertTrue(b.hiddenChatsForManagement.isEmpty)
    }

    func testEncryptedReopenAndUnhideDoNotChangeTheOtherSignOrNamespace() throws {
        let fixture = try VaultFixture()
        let account = fixture.config.selectedA
        let negative = ChatIdentity(account: account, peerNamespace: 3, peerID: -42)
        let positive = ChatIdentity(account: account, peerNamespace: 3, peerID: 42)
        let cloud = ChatIdentity(account: account, peerNamespace: 0, peerID: 42)
        var a = try fixture.store.authenticate(pin: "123456")
        for identity in [negative, positive, cloud] {
            do { a = try fixture.store.setHidden(identity, hidden: true, grant: a, expectedRevision: a.configurationRevision) }
            catch { XCTFail("Valid signed hidden chat refused: \(error)"); return }
        }
        let reopened = try fixture.reopen()
        let fresh = try reopened.authenticate(pin: "123456")
        XCTAssertEqual(try reopened.configuration(grant: fresh).hiddenChats, [negative, positive, cloud])
        let updated = try reopened.setHidden(negative, hidden: false, grant: fresh, expectedRevision: fresh.configurationRevision)
        XCTAssertThrowsError(try reopened.configuration(grant: fresh))
        XCTAssertEqual(try reopened.configuration(grant: updated).hiddenChats, [positive, cloud])
        let b = try reopened.authenticate(pin: "654321")
        let policy = AccessModePolicy(mode: .b, configuration: try reopened.configuration(grant: b))
        XCTAssertTrue(policy.discover(negative)); XCTAssertEqual(policy.explicitOpen(negative), .ordinary)
        XCTAssertFalse(policy.discover(positive)); XCTAssertEqual(policy.explicitOpen(positive), .restrictedTranscript)
        XCTAssertFalse(policy.discover(cloud)); XCTAssertEqual(policy.explicitOpen(cloud), .restrictedTranscript)
    }
}
