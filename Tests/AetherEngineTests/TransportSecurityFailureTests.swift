import Foundation
import Testing
@testable import AetherEngine

struct TransportSecurityFailureTests {

    private func urlError(_ code: Int, underlying: NSError? = nil) -> NSError {
        var info: [String: Any] = [:]
        if let underlying { info[NSUnderlyingErrorKey] = underlying }
        return NSError(domain: NSURLErrorDomain, code: code, userInfo: info)
    }

    @Test("AE#495: a self-signed origin is recognised where it is thrown")
    func recognisesUntrustedCertificate() {
        #expect(TransportSecurityFailure.code(in: urlError(NSURLErrorServerCertificateUntrusted))
                == NSURLErrorServerCertificateUntrusted)
        #expect(TransportSecurityFailure.isTrustFailure(urlError(NSURLErrorSecureConnectionFailed)))
    }

    @Test("AE#495: the URL error under AVFoundation's own is the one that says what happened")
    func walksTheUnderlyingChain() {
        let buried = urlError(NSURLErrorServerCertificateHasUnknownRoot)
        let middle = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost,
                             userInfo: [NSUnderlyingErrorKey: buried])
        let top = NSError(domain: "AVFoundationErrorDomain", code: -11800,
                          userInfo: [NSUnderlyingErrorKey: middle])
        #expect(TransportSecurityFailure.code(in: top) == NSURLErrorServerCertificateHasUnknownRoot)
    }

    @Test("AE#495: a transport failure that is not about trust stays unclassified")
    func leavesOtherFailuresAlone() {
        #expect(TransportSecurityFailure.code(in: urlError(NSURLErrorTimedOut)) == nil)
        #expect(TransportSecurityFailure.code(in: urlError(NSURLErrorNetworkConnectionLost)) == nil)
        #expect(TransportSecurityFailure.code(in: NSError(domain: "AVFoundationErrorDomain",
                                                          code: -11800)) == nil)
        #expect(TransportSecurityFailure.code(in: nil) == nil)
    }

    @Test("AE#495: a cyclic chain cannot hang the failure path")
    func boundedWalk() {
        let a = NSError(domain: "X", code: 1)
        let b = NSError(domain: "Y", code: 2, userInfo: [NSUnderlyingErrorKey: a])
        // Deep but finite, the shape a wrapper chain actually takes.
        var deep: NSError = b
        for i in 0..<40 {
            deep = NSError(domain: "W", code: i, userInfo: [NSUnderlyingErrorKey: deep])
        }
        #expect(TransportSecurityFailure.code(in: deep) == nil)
    }

    @Test("AE#495: every code has a sentence, and it names the fault rather than the number")
    func everyCodeReads() {
        for code in TransportSecurityFailure.codes {
            let sentence = TransportSecurityFailure.sentence(for: code)
            #expect(!sentence.isEmpty)
            #expect(!sentence.contains("\(code)"))
        }
        #expect(TransportSecurityFailure.sentence(for: NSURLErrorServerCertificateUntrusted)
                .contains("self-signed"))
    }

    @Test("AE#495: a failed item whose chain carries a trust refusal is published as one")
    func itemFailureIsClassified() {
        let buried = urlError(NSURLErrorServerCertificateUntrusted)
        let top = NSError(domain: "AVFoundationErrorDomain", code: -11800,
                          userInfo: [NSUnderlyingErrorKey: buried])
        let info = NativeAVPlayerHost.itemFailureInfo(desc: "The operation could not be completed",
                                                      itemError: top)
        #expect(info.kind == .sourceCertificateRejected)
        #expect(info.underlyingDomain == NSURLErrorDomain)
        #expect(info.underlyingCode == NSURLErrorServerCertificateUntrusted)
    }

    @Test("AE#495: an ordinary item failure keeps the kind and the message it always had")
    func itemFailureOtherwiseUnchanged() {
        let top = NSError(domain: "AVFoundationErrorDomain", code: -11819)
        let info = NativeAVPlayerHost.itemFailureInfo(desc: "Cannot Complete Action", itemError: top)
        #expect(info.kind == .nativeItemFailed)
        #expect(info.message == "Cannot Complete Action")
        #expect(info.underlyingCode == -11819)
    }

    @Test("AE#495: behind the relay the refusal is read off the side that made the handshake")
    func relayRefusalIsClassifiedWithoutAChain() {
        // The relay answers the player a plain 502 from loopback, so the item's error chain carries
        // no certificate anywhere. Without the relay's own verdict this reads as a bad gateway, which
        // is the one thing it is not.
        let asSeenThroughLoopback = NSError(domain: "AVFoundationErrorDomain", code: -11800)
        let info = NativeAVPlayerHost.itemFailureInfo(
            desc: "The operation could not be completed", itemError: asSeenThroughLoopback,
            relayRefusalCode: NSURLErrorServerCertificateUntrusted)
        #expect(info.kind == .sourceCertificateRejected)
        #expect(info.underlyingDomain == NSURLErrorDomain)
        #expect(info.underlyingCode == NSURLErrorServerCertificateUntrusted)
    }

    @Test("AE#495: a relay that never lost a handshake changes nothing")
    func relayWithoutARefusalIsInert() {
        let top = NSError(domain: "AVFoundationErrorDomain", code: -11819)
        let info = NativeAVPlayerHost.itemFailureInfo(desc: "Cannot Complete Action", itemError: top,
                                                      relayRefusalCode: nil)
        #expect(info.kind == .nativeItemFailed)
        #expect(info.underlyingCode == -11819)
    }

    @Test("AE#495: the typed refusal survives the HLS layer instead of being wrapped as invalid data")
    func typedRefusalSurvivesTheWrapper() {
        let passed = HLSVideoEngine.openFailure(
            from: AVIOReaderError.transportSecurityFailed(code: NSURLErrorServerCertificateUntrusted))
        guard case .transportSecurityFailed(let code) = (passed as? AVIOReaderError) else {
            Issue.record("expected the reader's typed error to pass through, got \(passed)")
            return
        }
        #expect(code == NSURLErrorServerCertificateUntrusted)

        // The control: anything else still arrives in the historical wrapped shape.
        let wrapped = HLSVideoEngine.openFailure(from: AVIOReaderError.requestTimeout)
        #expect(wrapped is HLSVideoEngine.HLSVideoEngineError)
    }
}
