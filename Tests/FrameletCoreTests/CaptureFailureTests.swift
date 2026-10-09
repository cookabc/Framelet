import ScreenCaptureKit
import XCTest

@testable import FrameletCore

final class CaptureFailureTests: XCTestCase {
    func testOnlyExplicitScreenCaptureDenialIsPermissionFailure() {
        XCTAssertTrue(CaptureFailure.isPermissionDenied(NSError(domain: SCStreamErrorDomain, code: -3801)))
        XCTAssertFalse(CaptureFailure.isPermissionDenied(NSError(domain: SCStreamErrorDomain, code: -3811)))
        XCTAssertFalse(CaptureFailure.isPermissionDenied(NSError(domain: SCStreamErrorDomain, code: -3802)))
        XCTAssertFalse(CaptureFailure.isPermissionDenied(NSError(domain: NSCocoaErrorDomain, code: -3801)))
    }

    func testRecognizesWrappedDenialWithoutTreatingOtherErrorsAsPermissionFailures() {
        let denied = NSError(domain: SCStreamErrorDomain, code: -3801)
        let wrapped = NSError(domain: "Framelet", code: 1, userInfo: [NSUnderlyingErrorKey: denied])
        XCTAssertTrue(CaptureFailure.isPermissionDenied(wrapped))
        XCTAssertFalse(CaptureFailure.isPermissionDenied(CancellationError()))
    }
}
