import XCTest
import Foundation
import SwiftSignalKit
import MtProtoKit
import TelegramApi
@testable import TelegramCore

private final class ScopeRecordingService: NetworkEngineRequestService {
    var requests: [NetworkEngineRequest] = []
    var disposed = 0
    func add(_ request: NetworkEngineRequest) -> Disposable {
        requests.append(request)
        return ActionDisposable { self.disposed += 1 }
    }
}

/// Captures the real Swift -> MTRequest conversion without a session, socket or
/// key creation. The production service's complete/cancel/move logic still runs.
private final class ScopeCapturingMTService: MTRequestMessageService {
    var requests: [MTRequest] = []
    var removed = 0
    override init() { super.init(context: nil) }
    override func add(_ request: MTRequest!) { requests.append(request) }
    override func removeRequest(byInternalId internalId: Any!) { removed += 1 }
}

final class NetworkAuthKeyScopeTests: XCTestCase {
    private var original: NetworkRequestAuthKeyScope {
        NetworkRequestAuthKeyScope(datacenterId: 2, permanentKeyDigest: Data(repeating: 0x51, count: 32))
    }

    private func engineRequest(scope: NetworkRequestAuthKeyScope?, completed: @escaping (Result<NetworkEngineResponse, NetworkEngineRequestFailure>) -> Void = { _ in }) -> NetworkEngineRequest {
        NetworkEngineRequest(payload: Data([1, 2, 3, 4]), metadata: WrappedRequestMetadata(metadata: "offline scope", tag: nil), shortMetadata: WrappedRequestShortMetadata(shortMetadata: "offline"), parse: { _ in true }, options: NetworkEngineRequestOptions(authKeyScope: scope), shouldContinueAfterError: { _ in false }, dependsOn: nil, acknowledged: nil, progress: nil, completed: completed)
    }

    func testLazySignalCarriesTheExactScopeUntilActualSubmission() {
        let service = ScopeRecordingService()
        let signal = networkRequestSignal(Api.functions.auth.logOut(), requestService: service, automaticFloodWait: false, authKeyScope: original)
        XCTAssertEqual(service.requests.count, 0)
        let disposable = signal.start()
        XCTAssertEqual(service.requests.count, 1)
        XCTAssertEqual(service.requests.first?.options.authKeyScope, original)
        XCTAssertFalse(service.requests[0].shouldContinueAfterError(NetworkEngineErrorContext(floodWaitSeconds: 1, floodWaitErrorText: "FLOOD_WAIT_1", internalServerErrorCount: 0)))
        disposable.dispose()
        XCTAssertEqual(service.disposed, 1)
    }

    func testMalformedScopeCannotReachTheRequestService() {
        for scope in [NetworkRequestAuthKeyScope(datacenterId: 0, permanentKeyDigest: original.permanentKeyDigest), NetworkRequestAuthKeyScope(datacenterId: -1, permanentKeyDigest: original.permanentKeyDigest), NetworkRequestAuthKeyScope(datacenterId: 2, permanentKeyDigest: Data(count: 31))] {
            let service = ScopeRecordingService()
            var error: MTRpcError?
            let disposable = networkRequestSignal(Api.functions.auth.logOut(), requestService: service, authKeyScope: scope).start(error: { error = $0 })
            XCTAssertEqual(service.requests.count, 0)
            XCTAssertEqual(error?.errorCode, 403)
            XCTAssertEqual(error?.errorDescription, "AUTHORIZATION_SCOPE_CHANGED")
            disposable.dispose()
        }
    }

    func testMtProtoKitConversionPreservesItsImmutableScope() {
        let captured = ScopeCapturingMTService()
        let adapter = MtProtoKitRequestService(requestService: captured)
        let disposable = adapter.add(engineRequest(scope: original))
        XCTAssertEqual(captured.requests.count, 1)
        XCTAssertEqual(captured.requests[0].authKeyScope?.datacenterId, original.datacenterId)
        XCTAssertEqual(captured.requests[0].authKeyScope?.permanentKeyDigest, original.permanentKeyDigest)
        disposable.dispose()
        XCTAssertEqual(captured.removed, 1)
    }

    func testMovedRequestKeepsScopeAndIgnoresOldCompletion() {
        let first = ScopeCapturingMTService(), second = ScopeCapturingMTService()
        let source = MtProtoKitRequestService(requestService: first), destination = MtProtoKitRequestService(requestService: second)
        var completed = 0
        let disposable = source.add(engineRequest(scope: original, completed: { _ in completed += 1 }))
        source.movePendingRequests(to: destination)
        XCTAssertEqual(first.removed, 1)
        XCTAssertEqual(second.requests.count, 1)
        XCTAssertEqual(second.requests[0].authKeyScope?.datacenterId, original.datacenterId)
        XCTAssertEqual(second.requests[0].authKeyScope?.permanentKeyDigest, original.permanentKeyDigest)
        first.requests[0].completed?(true, nil, nil)
        XCTAssertEqual(completed, 0)
        second.requests[0].completed?(true, nil, nil)
        XCTAssertEqual(completed, 1)
        disposable.dispose()
        XCTAssertEqual(second.removed, 1)
    }

    func testUnsupportedEngineCompletesProtectedRequestLocally() {
        var failures: [NetworkEngineRequestFailure] = []
        let request = engineRequest(scope: original, completed: { if case let .failure(error) = $0 { failures.append(error) } })
        XCTAssertFalse(request.failIfAuthKeyScopeUnsupported(engineKind: .mtProtoKit))
        XCTAssertTrue(failures.isEmpty)
        XCTAssertTrue(request.failIfAuthKeyScopeUnsupported(engineKind: .rust))
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first?.error.errorCode, 403)
        XCTAssertEqual(failures.first?.error.errorDescription, "AUTHORIZATION_SCOPE_CHANGED")
        XCTAssertFalse(engineRequest(scope: nil).failIfAuthKeyScopeUnsupported(engineKind: .rust))
    }

    func testOrdinarySignalAndConversionRetainNormalCompletion() {
        let service = ScopeRecordingService()
        var result: Api.Bool?
        let disposable = networkRequestSignal(Api.functions.account.resetAuthorization(hash: 1), requestService: service).start(next: { result = $0 })
        XCTAssertEqual(service.requests.count, 1)
        XCTAssertNil(service.requests[0].options.authKeyScope)
        service.requests[0].completed(.success(NetworkEngineResponse(result: BoxedMessage(Api.Bool.boolTrue), info: NetworkEngineResponseInfo(timestamp: 0, networkType: 0, duration: 0))))
        if case .boolTrue? = result {} else { XCTFail("ordinary response must complete") }
        disposable.dispose()
        let captured = ScopeCapturingMTService()
        let adapter = MtProtoKitRequestService(requestService: captured)
        let native = adapter.add(engineRequest(scope: nil))
        XCTAssertNil(captured.requests.first?.authKeyScope)
        native.dispose()
    }
}
