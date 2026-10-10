import Foundation

public enum AccessInitialSetupState: Equatable { case idle, preparing, finished }
public struct AccessInitialSetupRequest {
    let coordinator: UUID
    let generation: UUID
}

/// Main adapter must cover/detach before prepare, and dispatch execution off-main.
/// This coordinator never issues an account/data grant or opens a root.
public final class AccessInitialSetupCoordinator {
    private let id = UUID()
    private let store: AccessCredentialStore
    private let process: AccessProcess
    private let mutex = NSRecursiveLock()
    private var generation = UUID()
    private var presentation: AccessInitialSetupState = .idle
    public var state: AccessInitialSetupState {
        mutex.lock(); defer { mutex.unlock() }
        return presentation
    }
    public init(store: AccessCredentialStore, process: AccessProcess = .mainApplication) {
        self.store = store; self.process = process
    }
    public func prepare() throws -> AccessInitialSetupRequest {
        mutex.lock(); defer { mutex.unlock() }
        guard process == .mainApplication else { throw AccessError.authenticationRequired }
        guard presentation != .preparing else { throw AccessError.invalidTransition }
        generation = UUID()
        presentation = .finished
        guard try !store.isConfigured() else { throw AccessError.alreadyConfigured }
        presentation = .preparing
        return AccessInitialSetupRequest(coordinator: id, generation: generation)
    }
    public func cancel() {
        mutex.lock(); defer { mutex.unlock() }
        generation = UUID()
        presentation = .finished
    }
    public func execute(_ request: AccessInitialSetupRequest, operation: () throws -> AccessInitialSetupReceipt) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard process == .mainApplication, request.coordinator == id,
              request.generation == generation, presentation == .preparing else { throw AccessError.staleAuthorization }
        generation = UUID()
        let execution = generation
        let result = Result {
            // Another process may have created a vault since main preparation.
            // Never run its owner callback or revoke that other authority.
            guard try !store.isConfigured() else { throw AccessError.alreadyConfigured }
            let receipt = try operation()
            guard generation == execution, presentation == .preparing else { throw AccessError.staleAuthorization }
            try store.finishInitialSetup(receipt)
        }
        guard generation == execution else { throw AccessError.staleAuthorization }
        generation = UUID()
        presentation = .finished
        try result.get()
    }
}
