import Foundation
import ScreenCaptureKit

public enum CaptureFailure {
    /// Only an explicit denial is a permission error. Capture-service failures require different recovery.
    public static func isPermissionDenied(_ error: Error) -> Bool {
        var current = error as NSError
        for _ in 0..<8 {
            if current.domain == SCStreamErrorDomain
                && current.code == SCStreamError.Code.userDeclined.rawValue
            {
                return true
            }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { return false }
            current = underlying
        }
        return false
    }
}
