import XCTest
import UIKit
import AccessModeUI

final class PINManagementFeedbackTests: XCTestCase {
    func testFailureAppearsOnlyAfterExactOperationCompletes() throws {
        let feedback = PINManagementFeedback()
        XCTAssertFalse(feedback.isPending); XCTAssertFalse(feedback.hasFailure)
        let ticket = try feedback.begin()
        XCTAssertTrue(feedback.isPending); XCTAssertFalse(feedback.hasFailure)
        XCTAssertThrowsError(try feedback.begin())
        XCTAssertTrue(feedback.finish(ticket, failed: true))
        XCTAssertFalse(feedback.isPending); XCTAssertTrue(feedback.hasFailure)
        XCTAssertFalse(feedback.finish(ticket, failed: false))
        XCTAssertTrue(feedback.hasFailure)
    }

    func testForeignOrOldCompletionCannotRemoveCurrentCoverOrShowAnError() throws {
        let feedback = PINManagementFeedback()
        let foreign = try PINManagementFeedback().begin()
        let old = try feedback.begin()
        XCTAssertTrue(feedback.finish(old, failed: false))
        let current = try feedback.begin()
        XCTAssertFalse(feedback.finish(old, failed: true))
        XCTAssertFalse(feedback.finish(foreign, failed: true))
        XCTAssertTrue(feedback.isPending); XCTAssertFalse(feedback.hasFailure)
        XCTAssertTrue(feedback.finish(current, failed: false))
        XCTAssertFalse(feedback.isPending); XCTAssertFalse(feedback.hasFailure)
    }

    func testInactiveCancellationRetainsPendingCoverButSuppressesLaterError() throws {
        let feedback = PINManagementFeedback()
        let ticket = try feedback.begin()
        feedback.invalidate()
        XCTAssertTrue(feedback.isPending)
        XCTAssertThrowsError(try feedback.begin())
        XCTAssertTrue(feedback.finish(ticket, failed: true))
        XCTAssertFalse(feedback.isPending); XCTAssertFalse(feedback.hasFailure)
        let next = try feedback.begin()
        XCTAssertTrue(feedback.finish(next, failed: true)); XCTAssertTrue(feedback.hasFailure)
        feedback.invalidate(); XCTAssertFalse(feedback.hasFailure)
    }

    func testOlderJournalRecoveryCannotClearANewerFailureOrPendingChange() throws {
        let feedback = PINManagementFeedback()
        let first = try feedback.begin()
        XCTAssertTrue(feedback.finish(first, failed: true))
        let old = feedback.captureRevision()
        let second = try feedback.begin()
        XCTAssertFalse(feedback.clearRecoveredFailure(old)); XCTAssertTrue(feedback.isPending)
        XCTAssertTrue(feedback.finish(second, failed: true))
        XCTAssertFalse(feedback.clearRecoveredFailure(old)); XCTAssertTrue(feedback.hasFailure)
        let current = feedback.captureRevision()
        XCTAssertTrue(feedback.clearRecoveredFailure(current)); XCTAssertFalse(feedback.hasFailure)
        XCTAssertFalse(feedback.clearRecoveredFailure(current))
    }

    func testRecoveryFromAnotherInstanceCannotClearCurrentFailure() throws {
        let feedback = PINManagementFeedback()
        let ticket = try feedback.begin(); XCTAssertTrue(feedback.finish(ticket, failed: true))
        XCTAssertFalse(feedback.clearRecoveredFailure(PINManagementFeedback().captureRevision()))
        XCTAssertTrue(feedback.hasFailure)
        let beforeInactive = feedback.captureRevision()
        feedback.invalidate()
        XCTAssertFalse(feedback.clearRecoveredFailure(beforeInactive))
    }
}
