import Foundation

// Note for the future Windows shell: `URLSession.bytes(for:)` is Apple-only. When
// porting, swap this file's transport; the request builders and decoders are portable.

enum HTTPStreaming {
    /// Opens a streaming request and hands back its lines, after turning non-2xx
    /// responses into `LLMError`s using `errorMessage` to read the body.
    static func lines(
        for request: URLRequest,
        session: URLSession,
        unreachableMessage: String,
        errorMessage: @Sendable (Int, Data) -> LLMError
    ) async throws -> AsyncLineSequence<URLSession.AsyncBytes> {
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch let error as URLError where error.isConnectionFailure {
            throw LLMError.unreachable(unreachableMessage)
        }
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse("not an HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count > 16_384 { break }
            }
            throw errorMessage(http.statusCode, body)
        }
        return bytes.lines
    }

    static func data(
        for request: URLRequest,
        session: URLSession,
        unreachableMessage: String
    ) async throws -> (Data, Int) {
        do {
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch let error as URLError where error.isConnectionFailure {
            throw LLMError.unreachable(unreachableMessage)
        }
    }
}

extension URLError {
    var isConnectionFailure: Bool {
        [.cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet, .timedOut, .dnsLookupFailed]
            .contains(code)
    }
}
