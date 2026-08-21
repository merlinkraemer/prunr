import XCTest
@testable import Prunr

final class FeedbackServiceRegressionTests: XCTestCase {
    func testMapTransportFailureMapsOfflineAndTimeoutCodes() {
        let codes: [URLError.Code] = [
            .notConnectedToInternet,
            .networkConnectionLost,
            .timedOut,
            .cannotFindHost,
            .dnsLookupFailed,
            .cannotConnectToHost,
            .internationalRoamingOff,
            .callIsActive,
            .dataNotAllowed,
        ]

        for code in codes {
            let mapped = FeedbackServiceError.mapTransportFailure(URLError(code))
            guard case .networkUnavailable = mapped else {
                XCTFail("Expected networkUnavailable for \(code)")
                continue
            }
        }
    }

    func testMapTransportFailureIgnoresNonNetworkErrors() {
        XCTAssertNil(FeedbackServiceError.mapTransportFailure(URLError(.cancelled)))
        XCTAssertNil(FeedbackServiceError.mapTransportFailure(URLError(.badURL)))
        XCTAssertNil(FeedbackServiceError.mapTransportFailure(FeedbackServiceError.invalidResponse))
        XCTAssertNil(FeedbackServiceError.mapTransportFailure(FeedbackServiceError.rejected("server")))
    }

    func testNetworkUnavailableMessageMentionsRetryAndEmail() {
        let message = FeedbackServiceError.networkUnavailableMessage
        XCTAssertEqual(
            FeedbackServiceError.networkUnavailable.localizedDescription,
            message
        )
        XCTAssertTrue(message.contains("Could not send feedback"))
        XCTAssertTrue(message.contains("Reconnect to the internet"))
        XCTAssertTrue(message.contains("merlinkraemer@gmail.com"))
    }
}
