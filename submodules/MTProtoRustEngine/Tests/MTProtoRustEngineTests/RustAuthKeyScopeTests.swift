import XCTest
import Foundation
import SwiftSignalKit
import MtProtoKit
@testable import TelegramCore
@testable import MTProtoRustEngine

private final class RustScopeCapturingService: MTRequestMessageService {
    var requests: [MTRequest] = []
    var removed = 0
    override init() { super.init(context: nil) }
    override func add(_ request: MTRequest!) { requests.append(request) }
    override func removeRequest(byInternalId internalId: Any!) { removed += 1 }
}

final class RustAuthKeyScopeTests: XCTestCase {
    private func request(scope: NetworkRequestAuthKeyScope?, completed: @escaping (Result<NetworkEngineResponse, NetworkEngineRequestFailure>) -> Void) -> NetworkEngineRequest {
        NetworkEngineRequest(payload: Data([1, 2, 3, 4]), metadata: WrappedRequestMetadata(metadata: "offline scope", tag: nil), shortMetadata: WrappedRequestShortMetadata(shortMetadata: "offline"), parse: { _ in true }, options: NetworkEngineRequestOptions(authKeyScope: scope), shouldContinueAfterError: { _ in false }, dependsOn: nil, acknowledged: nil, progress: nil, completed: completed)
    }

    func testProtectedRequestIsRejectedByActualRustServiceWithoutCreatingASession() {
        let service = RustRequestService()
        XCTAssertNil(service.session)
        for scope in [NetworkRequestAuthKeyScope(datacenterId: 2, permanentKeyDigest: Data(count: 32)), NetworkRequestAuthKeyScope(datacenterId: 0, permanentKeyDigest: Data())] {
            var failure: NetworkEngineRequestFailure?
            let disposable = service.add(request(scope: scope, completed: { if case let .failure(value) = $0 { failure = value } }))
            XCTAssertEqual(failure?.error.errorCode, 403)
            XCTAssertEqual(failure?.error.errorDescription, "AUTHORIZATION_SCOPE_CHANGED")
            XCTAssertNil(service.session)
            disposable.dispose()
        }
    }

    func testPendingMtProtoRequestMovedToRustFailsAndCannotAcceptItsOldReply() {
        let captured = RustScopeCapturingService()
        let source = MtProtoKitRequestService(requestService: captured)
        let destination = RustRequestService()
        var completions = 0
        var error: MTRpcError?
        let disposable = source.add(request(scope: NetworkRequestAuthKeyScope(datacenterId: 2, permanentKeyDigest: Data(count: 32)), completed: {
            completions += 1
            if case let .failure(failure) = $0 { error = failure.error }
        }))
        source.movePendingRequests(to: destination)
        XCTAssertEqual(captured.removed, 1)
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(error?.errorDescription, "AUTHORIZATION_SCOPE_CHANGED")
        captured.requests[0].completed?(true, nil, nil)
        XCTAssertEqual(completions, 1, "old transport reply cannot undo local refusal")
        disposable.dispose()
        XCTAssertNil(destination.session)
    }

    func testOrdinaryRequestRetainsExistingMissingSessionBehavior() {
        let service = RustRequestService()
        var completed = false
        let disposable = service.add(request(scope: nil, completed: { _ in completed = true }))
        XCTAssertFalse(completed)
        XCTAssertNil(service.session)
        disposable.dispose()
    }
}
