import AccessModeCore

/// The root adapter must validate the preparation ticket and build a fresh permitted
/// UI before completing preparation/unlocking. This callback never yields a legacy
/// PasscodeSession and cannot unlock the app by itself.
public struct ModePINEntryAuthentication {
    let coordinator: AccessModeCoordinator
    let prepareRoot: (AccessTicket) throws -> Void

    public var presentationState: AccessPresentationState { coordinator.state }

    public init(coordinator: AccessModeCoordinator, prepareRoot: @escaping (AccessTicket) throws -> Void) {
        self.coordinator = coordinator
        self.prepareRoot = prepareRoot
    }
}
