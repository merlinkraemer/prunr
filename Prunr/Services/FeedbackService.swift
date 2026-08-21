import Foundation

struct FeedbackSubmission: Encodable {
    let token: String
    let message: String
    let email: String?
    let diagnosticsBase64: String
    let appVersion: String
    let macOSVersion: String
    let installId: String
}

enum FeedbackServiceError: LocalizedError {
    case invalidResponse
    case rejected(String)
    case networkUnavailable

    static let mailtoFallbackAddress = "merlinkraemer@gmail.com"

    /// Shared mailto line included in every user-facing send failure.
    static let mailtoFallbackMessage =
        "Or email \(mailtoFallbackAddress) directly."

    static let networkUnavailableMessage =
        "Could not send feedback. Reconnect to the internet and try again, or email \(mailtoFallbackAddress) directly."

    /// User-facing copy for non-network send failures (always includes mailto).
    static func userFacingMessage(for error: Error) -> String {
        if let serviceError = error as? FeedbackServiceError {
            switch serviceError {
            case .networkUnavailable:
                return networkUnavailableMessage
            case .invalidResponse:
                return "Could not send feedback. The service returned an unexpected response. \(mailtoFallbackMessage)"
            case .rejected(let message):
                let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
                let base = trimmed.isEmpty
                    ? "Could not send feedback. Please try again later."
                    : trimmed
                if base.localizedCaseInsensitiveContains(mailtoFallbackAddress) {
                    return base
                }
                return "\(base) \(mailtoFallbackMessage)"
            }
        }
        return "Could not send feedback: \(error.localizedDescription) \(mailtoFallbackMessage)"
    }

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The feedback service returned an unexpected response. \(Self.mailtoFallbackMessage)"
        case .rejected(let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            let base = trimmed.isEmpty
                ? "Could not send feedback. Please try again later."
                : trimmed
            if base.localizedCaseInsensitiveContains(Self.mailtoFallbackAddress) {
                return base
            }
            return "\(base) \(Self.mailtoFallbackMessage)"
        case .networkUnavailable:
            return Self.networkUnavailableMessage
        }
    }

    /// Maps URLSession transport failures (offline, timeout, DNS, connection) to a typed error.
    /// Returns nil for non-network errors so HTTP/server handling stays unchanged.
    static func mapTransportFailure(_ error: Error) -> FeedbackServiceError? {
        guard let urlError = error as? URLError else { return nil }
        switch urlError.code {
        case .notConnectedToInternet,
             .networkConnectionLost,
             .timedOut,
             .cannotFindHost,
             .dnsLookupFailed,
             .cannotConnectToHost,
             .internationalRoamingOff,
             .callIsActive,
             .dataNotAllowed:
            return .networkUnavailable
        default:
            return nil
        }
    }
}

enum FeedbackService {
    static let endpoint = URL(string: "https://prunr-web.vercel.app/api/feedback")!
    static let sharedToken = "prunr-alpha-feedback-v1"
    static let installIDKey = "feedbackInstallID"

    static var installID: String {
        if let existing = UserDefaults.standard.string(forKey: installIDKey) {
            return existing
        }
        let generated = UUID().uuidString.lowercased()
        UserDefaults.standard.set(generated, forKey: installIDKey)
        return generated
    }

    static func send(message: String, email: String?, diagnostics: Data) async throws {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let submission = FeedbackSubmission(
            token: sharedToken,
            message: message,
            email: email?.isEmpty == false ? email : nil,
            diagnosticsBase64: diagnostics.base64EncodedString(),
            appVersion: "\(shortVersion) (\(build))",
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            installId: installID
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(submission)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            if let mapped = FeedbackServiceError.mapTransportFailure(error) {
                throw mapped
            }
            throw error
        }

        guard let http = response as? HTTPURLResponse else {
            throw FeedbackServiceError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let responseError = (try? JSONDecoder().decode(FeedbackErrorResponse.self, from: data))?.error
            throw FeedbackServiceError.rejected(responseError ?? "Could not send feedback. Please try again later.")
        }
    }
}

private struct FeedbackErrorResponse: Decodable {
    let error: String
}
