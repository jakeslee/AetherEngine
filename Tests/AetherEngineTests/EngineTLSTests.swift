import Foundation
import Testing

@testable import AetherEngine

// Self-signed and private-CA media servers fail URLSession's system trust,
// which the FFmpeg stack never enforced, so hosts need an explicit opt-in.
// The resolver must stay on default handling for everything except a
// server-trust challenge the host answered for.
@Suite("EngineTLS trust resolution", .serialized)
struct EngineTLSTests {

    private final class RecordingSender: NSObject, URLAuthenticationChallengeSender {
        func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
        func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
        func cancel(_ challenge: URLAuthenticationChallenge) {}
    }

    private func challenge(
        method: String, host: String = "server.example"
    ) -> URLAuthenticationChallenge {
        let space = URLProtectionSpace(
            host: host, port: 443, protocol: "https",
            realm: nil, authenticationMethod: method)
        return URLAuthenticationChallenge(
            protectionSpace: space, proposedCredential: nil, previousFailureCount: 0,
            failureResponse: nil, error: nil, sender: RecordingSender())
    }

    private func disposition(
        evaluator: (@Sendable (URLProtectionSpace) -> Bool)?,
        method: String,
        host: String = "server.example"
    ) -> URLSession.AuthChallengeDisposition {
        let previous = EngineTLS.serverTrustEvaluator
        defer { EngineTLS.serverTrustEvaluator = previous }
        EngineTLS.serverTrustEvaluator = evaluator

        var got: URLSession.AuthChallengeDisposition?
        EngineTLS.resolve(challenge(method: method, host: host)) { disposition, _ in
            got = disposition
        }
        return got ?? .performDefaultHandling
    }

    @Test("No evaluator keeps default handling for server trust")
    func noEvaluatorServerTrust() {
        #expect(
            disposition(evaluator: nil, method: NSURLAuthenticationMethodServerTrust)
                == .performDefaultHandling)
    }

    @Test("Non-trust challenges never reach the evaluator")
    func httpAuthUntouched() {
        let asked = Mutex(false)
        let got = disposition(
            evaluator: { _ in asked.set(true); return true },
            method: NSURLAuthenticationMethodHTTPBasic)

        #expect(got == .performDefaultHandling)
        #expect(asked.get() == false, "HTTP auth is not a trust decision the host was asked for")
    }

    @Test("The evaluator is asked about the origin the challenge came from")
    func evaluatorSeesTheOrigin() {
        let seen = Mutex<String?>(nil)
        _ = disposition(
            evaluator: { space in seen.set(space.host); return false },
            method: NSURLAuthenticationMethodServerTrust,
            host: "lan.media.example")

        #expect(seen.get() == "lan.media.example")
    }

    @Test("An evaluator that declines keeps default handling")
    func decliningEvaluator() {
        #expect(
            disposition(evaluator: { _ in false }, method: NSURLAuthenticationMethodServerTrust)
                == .performDefaultHandling)
    }

    @Test("An accepted challenge with no evaluable trust object stays on default handling")
    func acceptedWithoutTrustObject() {
        // A challenge built outside a live handshake carries no SecTrust, so
        // the resolver must fall through rather than send a nil credential.
        #expect(
            disposition(evaluator: { _ in true }, method: NSURLAuthenticationMethodServerTrust)
                == .performDefaultHandling)
    }

    /// The evaluator is `@Sendable` and runs on whichever queue raised the
    /// challenge, so a test recording what it saw cannot capture a plain var.
    private final class Mutex<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value

        init(_ value: Value) { self.value = value }
        func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ newValue: Value) { lock.lock(); value = newValue; lock.unlock() }
    }
}
