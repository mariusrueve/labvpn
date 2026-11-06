import Foundation
import Testing
@testable import LabVPNCore
import Darwin

@Suite struct AuthResultTests {
    @Test func parsesAuthenticateOutput() {
        let output = """
        POST https://vpn.example.de/
        COOKIE='abc@def=='
        HOST='141.1.2.3'
        CONNECT_URL='https://vpn2-aux2.rrz.uni-hamburg.de/VPNZBH'
        FINGERPRINT='pin-sha256:elgCmsPTKxAlxrJcc1XbCyvNnwGWFhRw8jnCo2rYS4M='
        RESOLVE='vpn2-aux2.rrz.uni-hamburg.de:141.1.2.3'
        """
        let result = AuthResult.parse(output)
        #expect(result?.cookie == "abc@def==")
        #expect(result?.connectURL == "https://vpn2-aux2.rrz.uni-hamburg.de/VPNZBH")
        #expect(result?.resolve == "vpn2-aux2.rrz.uni-hamburg.de:141.1.2.3")
    }

    @Test func handlesEscapedQuoteAndMissingResolve() {
        let output = "COOKIE='a'\\''b'\nHOST=h\nCONNECT_URL=https://h/\nFINGERPRINT=f\n"
        #expect(AuthResult.parse(output)?.cookie == "a'b")
        #expect(AuthResult.parse(output)?.resolve == nil)
    }

    @Test func redirectedIPv6NodeIsMovedToIPv4() {
        let auth = AuthResult(cookie: "c", host: "h", connectURL: "https://vpn-asa2.rrz.uni-hamburg.de/", fingerprint: "f",
                              resolve: "vpn-asa2.rrz.uni-hamburg.de:2001:638:710:445::c1ae:a742")
        let moved = auth.preferringIPv4 { $0 == "vpn-asa2.rrz.uni-hamburg.de" ? "193.174.167.66" : nil }
        #expect(moved.resolve == "vpn-asa2.rrz.uni-hamburg.de:193.174.167.66")
        #expect(moved.cookie == "c")
    }

    @Test func ipv4PinIsKeptAndMissingARecordChangesNothing() {
        let pinned = AuthResult(cookie: "c", host: "h", connectURL: "https://a.de/", fingerprint: "f", resolve: "a.de:1.2.3.4")
        #expect(pinned.preferringIPv4 { _ in "9.9.9.9" } == pinned)
        let ipv6 = AuthResult(cookie: "c", host: "h", connectURL: "https://a.de/", fingerprint: "f", resolve: "a.de:::1")
        #expect(ipv6.preferringIPv4 { _ in nil } == ipv6)
    }

    @Test func rejectsIncompleteOutput() {
        #expect(AuthResult.parse("COOKIE='a'\nHOST='b'\n") == nil)
        #expect(AuthResult.parse("Login failed") == nil)
    }
}

@Suite struct ConnectRequestTests {
    let pin = "pin-sha256:elgCmsPTKxAlxrJcc1XbCyvNnwGWFhRw8jnCo2rYS4M="

    func request(url: String = "https://vpn2-aux2.rrz.uni-hamburg.de/VPNZBH", cookie: String = "c",
                 fingerprint: String? = nil, resolve: String? = "vpn.rrz.uni-hamburg.de:134.100.1.1",
                 mtu: Int? = nil, timeout: Int = 15) -> ConnectRequest {
        ConnectRequest(connectURL: url, cookie: cookie, fingerprint: fingerprint ?? pin,
                       resolve: resolve, mtu: mtu, reconnectTimeout: timeout)
    }

    @Test func acceptsValidRequest() throws {
        try request().validate()
        try request(resolve: nil, mtu: 1347).validate()
        try request(resolve: "vpn.rrz.uni-hamburg.de:2001:638:710:2ef::8664:39b2").validate()
        try request(resolve: "vpn.rrz.uni-hamburg.de:[2001:638:710:2ef::8664:39b2]").validate()
    }

    @Test(arguments: [
        "http://vpn.rrz.uni-hamburg.de/", "--script=/tmp/x", "https://user@vpn.rrz.uni-hamburg.de/",
        "https://vpn.rrz.uni-hamburg.de/a b", "https://vpn.rrz.uni-hamburg.de/?x=1", "https://-bad.uni-hamburg.de/",
    ])
    func rejectsBadURLs(url: String) {
        #expect(throws: ValidationError.invalidURL) { try request(url: url).validate() }
    }

    @Test func acceptsAnyGateway() throws {
        try request(url: "https://vpn.example.org/GROUP").validate()
    }

    @Test func rejectsBadValues() {
        #expect(throws: ValidationError.invalidCookie) { try request(cookie: "a\nb").validate() }
        #expect(throws: ValidationError.invalidCookie) { try request(cookie: "").validate() }
        #expect(throws: ValidationError.invalidFingerprint) { try request(fingerprint: "--script=/x").validate() }
        #expect(throws: ValidationError.invalidResolve) { try request(resolve: "host:notanip").validate() }
        #expect(throws: ValidationError.invalidMTU) { try request(mtu: 9000).validate() }
        #expect(throws: ValidationError.invalidTimeout) { try request(timeout: 0).validate() }
    }

    @Test func cookieIsNeverOnArgv() {
        let arguments = request(cookie: "SECRET").openconnectArguments(wrapperPath: "/w.sh")
        #expect(!arguments.joined().contains("SECRET"))
        #expect(arguments.last == "https://vpn2-aux2.rrz.uni-hamburg.de/VPNZBH")
        #expect(arguments.contains("--script=/w.sh"))
    }
}

@Suite struct LogRedactorTests {
    @Test func redactsSecrets() {
        #expect(!LogRedactor.redact("Set-Cookie: webvpn=abc123; path=/").contains("abc123"))
        #expect(!LogRedactor.redact("sent webvpn=abc123; path=/").contains("abc123"))
        #expect(!LogRedactor.redact("COOKIE=abc").contains("abc"))
        #expect(!LogRedactor.redact("got xyz here", secrets: ["xyz"]).contains("xyz"))
        #expect(LogRedactor.redact("Connected as 141.1.2.3") == "Connected as 141.1.2.3")
    }
}

@Suite struct ProfileTests {
    @Test func authenticateArgumentsMatchAuthType() throws {
        let profiles = Profile.presets(username: "bax1234")
        let zbh = profiles[0].authenticateArguments()
        #expect(zbh.contains("--passwd-on-stdin"))
        #expect(zbh.last == "vpn2-aux2.rrz.uni-hamburg.de/VPNZBH")
        let uhh = profiles[1].authenticateArguments()
        #expect(uhh.contains("--external-browser=/usr/bin/open"))
        #expect(!uhh.contains("--passwd-on-stdin"))
    }

    @Test func pinsGatewayAddressForAuthentication() {
        let zbh = Profile.presets(username: "u")[0]
        #expect(zbh.gatewayHostname == "vpn2-aux2.rrz.uni-hamburg.de")
        #expect(zbh.authenticateArguments(resolve: "h:1.2.3.4").contains("--resolve=h:1.2.3.4"))
        #expect(!zbh.authenticateArguments().contains { $0.hasPrefix("--resolve") })
    }

    @Test func resolvesIPv4Only() {
        #expect(GatewayResolver.ipv4Address(hostname: "127.0.0.1") == "127.0.0.1")
        #expect(GatewayResolver.ipv4Address(hostname: "::1") == nil)
        #expect(GatewayResolver.resolveArgument(hostname: "localhost") == "localhost:127.0.0.1")
    }

    @Test func storeRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + "/profiles.json")
        let store = ProfileStore(defaultProfile: "zbh", profiles: Profile.presets(username: "u"))
        try store.save(to: url)
        let loaded = try ProfileStore.load(from: url)
        #expect(loaded == store)
        #expect(loaded.profile(id: nil)?.id == "zbh")
        #expect(loaded.profile(id: "nope") == nil)
    }
}

@Suite struct TunnelProbeTests {
    @Test func parsesTunnelEnvironment() {
        let text = "INTERNAL_IP4_DNS=134.100.33.240 134.100.9.61\nTUNDEV=utun6\nVPNGATEWAY=1.2.3.4\n"
        #expect(TunnelEnvironment.parse(text) == TunnelEnvironment(interface: "utun6", dnsServers: ["134.100.33.240", "134.100.9.61"]))
        #expect(TunnelEnvironment.parse("TUNDEV=utun6\n") == nil)
    }

    @Test func acceptsMatchingReplyAndTimesOutOtherwise() throws {
        let server = socket(AF_INET, SOCK_DGRAM, 0)
        defer { close(server) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer -> Int32 in
                _ = bind(server, pointer, size)
                return getsockname(server, pointer, &size)
            }
        }
        #expect(bound == 0)
        let port = UInt16(bigEndian: address.sin_port)

        Thread.detachNewThread {
            var packet = [UInt8](repeating: 0, count: 512)
            var peer = sockaddr_storage()
            var peerSize = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let length = withUnsafeMutablePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(server, &packet, 512, 0, $0, &peerSize) }
            }
            packet[2] |= 0x80
            _ = withUnsafePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(server, packet, length, 0, $0, peerSize) }
            }
        }
        #expect(TunnelProbe.dnsResponds(server: "127.0.0.1", port: port, interface: nil, timeout: 10))
        // The responder answers only once, so this one must time out.
        #expect(!TunnelProbe.dnsResponds(server: "127.0.0.1", port: port, interface: nil, timeout: 0.2))
    }

    @Test func refusesUnknownInterface() {
        #expect(!TunnelProbe.dnsResponds(server: "127.0.0.1", interface: "utun999", timeout: 0.1))
    }
}

@Suite struct TunnelSupervisorTests {
    final class Fake {
        var running = true, healthy = true
        var startResults: [Bool] = []
        var silentStarts: Set<Int> = []
        var helperDown = false
        var logoffs = 0
        var healthyAfterStart = true
        var reauth: ReauthResult = .retryLater
        var startedCookies: [String] = []
        var stops = 0, reauths = 0
        var waits: [TimeInterval] = []
        var maxLoops = 50

        func supervisor() -> TunnelSupervisor {
            TunnelSupervisor(auth: TunnelSupervisorTests.make("old"), actions: .init(
                isRunning: { self.running },
                isHealthy: { self.healthy },
                stopKeepingSession: { self.stops += 1; self.running = false },
                start: { auth in
                    if self.helperDown { return false }
                    self.startedCookies.append(auth.cookie)
                    // false means openconnect started and then exited.
                    let ok = self.startResults.isEmpty ? true : self.startResults.removeFirst()
                    let silent = self.silentStarts.contains(self.startedCookies.count - 1)
                    self.running = ok || silent
                    self.healthy = ok && self.healthyAfterStart && !silent
                    return true
                },
                reauthenticate: { self.reauths += 1; return self.reauth },
                wait: { self.waits.append($0) },
                stopLoggingOff: { self.logoffs += 1; self.running = false },
                isCancelled: { self.waits.count > self.maxLoops },
                log: { _ in }
            ))
        }
    }

    static func make(_ cookie: String) -> AuthResult {
        AuthResult(cookie: cookie, host: "h", connectURL: "https://h/", fingerprint: "f", resolve: nil)
    }

    @Test func healthyTunnelIsLeftAlone() {
        let fake = Fake()
        #expect(fake.supervisor().tick() == .healthy)
        #expect(fake.startedCookies.isEmpty)
    }

    @Test func aliveButSilentTunnelRestartsAfterThreshold() {
        let fake = Fake()
        fake.healthy = false
        let supervisor = fake.supervisor()
        #expect(supervisor.tick() == .degraded)
        #expect(supervisor.tick() == .degraded)
        #expect(fake.startedCookies.isEmpty)
        #expect(supervisor.tick() == .recovered)
        #expect(fake.startedCookies == ["old"])
        #expect(fake.stops == 1)
        #expect(fake.reauths == 0)
    }

    @Test func singleBlipDoesNotAccumulate() {
        let fake = Fake()
        let supervisor = fake.supervisor()
        fake.healthy = false
        _ = supervisor.tick(); _ = supervisor.tick()
        fake.healthy = true
        #expect(supervisor.tick() == .healthy)
        fake.healthy = false
        #expect(supervisor.tick() == .degraded)
    }

    @Test func rejectedCookieReauthenticatesAndKeepsNewCookie() {
        let fake = Fake()
        fake.running = false
        fake.startResults = [false, true]
        fake.reauth = .success(Self.make("new"))
        #expect(fake.supervisor().tick() == .recovered)
        #expect(fake.startedCookies == ["old", "new"])
    }

    @Test func backsOffWhileOffline() {
        let fake = Fake()
        fake.running = false
        fake.startResults = [false, false, false, false, false, true]
        #expect(fake.supervisor().tick() == .recovered)
        #expect(fake.waits.filter { $0 > 1 } == [5, 10, 30, 60, 60])
    }

    @Test func rejectedPasswordStopsImmediately() {
        let fake = Fake()
        fake.running = false
        fake.startResults = [false]
        fake.reauth = .needsUser("rejected")
        #expect(fake.supervisor().tick() == .needsUser("rejected"))
        #expect(fake.reauths == 1)
    }

    @Test func networkChangeSkipsTheFailureWait() {
        let fake = Fake()
        #expect(fake.supervisor().networkChanged() == .recovered)
        #expect(fake.startedCookies == ["old"])
        #expect(fake.stops == 1)
    }

    @Test func wakeRecoversOnFirstFailedCheck() {
        let fake = Fake()
        fake.healthy = false
        #expect(fake.supervisor().didWake() == .recovered)
    }

    @Test func wakeLeavesHealthyTunnelAlone() {
        let fake = Fake()
        #expect(fake.supervisor().didWake() == .healthy)
        #expect(fake.startedCookies.isEmpty)
    }

    @Test func autoRecoverOffReportsLoss() {
        let fake = Fake()
        fake.running = false
        let supervisor = fake.supervisor()
        supervisor.autoRecover = false
        #expect(supervisor.tick() == .lost)
        #expect(fake.startedCookies.isEmpty)
    }

    @Test func silentTunnelNeverLogsInAgain() {
        let fake = Fake()
        fake.running = false
        fake.healthyAfterStart = false
        fake.reauth = .success(Self.make("new"))
        #expect(fake.supervisor().tick() == .cancelled)
        #expect(fake.reauths == 0)
        #expect(fake.startedCookies.allSatisfy { $0 == "old" })
    }

    @Test func helperDownDoesNotLogInAgain() {
        let fake = Fake()
        fake.running = false
        fake.helperDown = true
        #expect(fake.supervisor().tick() == .cancelled)
        #expect(fake.reauths == 0)
    }

    @Test func failedFreshCookieIsLoggedOff() {
        let fake = Fake()
        fake.running = false
        fake.startResults = [false, false, true]
        fake.silentStarts = [1]
        fake.reauth = .success(Self.make("new"))
        #expect(fake.supervisor().tick() == .recovered)
        #expect(fake.logoffs == 1)
        #expect(fake.startedCookies == ["old", "new", "new"])
    }
}

@Suite struct SettingsTests {
    @Test func oldProfilesFileLoadsWithDefaults() throws {
        let json = #"{"defaultProfile":"zbh","profiles":[]}"#
        let store = try JSONDecoder().decode(ProfileStore.self, from: Data(json.utf8))
        #expect(store.settings == AppSettings())
        #expect(store.settings.connectOnLaunch)
    }

    @Test func partialSettingsKeepOtherDefaults() throws {
        let json = #"{"defaultProfile":"zbh","profiles":[],"settings":{"connectOnLaunch":false}}"#
        let store = try JSONDecoder().decode(ProfileStore.self, from: Data(json.utf8))
        #expect(!store.settings.connectOnLaunch)
        #expect(store.settings.autoReconnect)
    }
}

@Suite struct AuthClassificationTests {
    @Test func rejectedPasswordStopsAndNetworkErrorRetries() {
        #expect(Authenticator.classify(status: 1, output: "", errors: "Login failed.\n") != .retryLater)
        #expect(Authenticator.classify(status: 1, output: "", errors: "User input required in non-interactive mode") != .retryLater)
        #expect(Authenticator.classify(status: 1, output: "", errors: "Failed to connect to host") == .retryLater)
    }
}

final class FakeHelper: TunnelHelper, @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    private(set) var requests: [ConnectRequest] = []
    private(set) var logoffs = 0
    private(set) var keeps = 0
    var failConnect = false
    var rejectCookies = false

    func connect(_ request: ConnectRequest) -> String? {
        lock.lock(); defer { lock.unlock() }
        if failConnect { return "no helper" }
        requests.append(request)
        running = !rejectCookies
        return nil
    }
    func disconnectKeepSession() -> String? { lock.lock(); defer { lock.unlock() }; keeps += 1; running = false; return nil }
    func disconnectLogoff() -> String? { lock.lock(); defer { lock.unlock() }; logoffs += 1; running = false; return nil }
    func status() -> HelperStatus? { lock.lock(); defer { lock.unlock() }; return HelperStatus(running: running) }
    func kill() { lock.lock(); defer { lock.unlock() }; running = false }
}

final class FakeAuth: Authenticating, @unchecked Sendable {
    var result = ReauthResult.success(TunnelSupervisorTests.make("cookie"))
    var results: [ReauthResult] = []
    private(set) var calls = 0
    func authenticate(_ profile: Profile, interactive: Bool) -> ReauthResult {
        calls += 1
        return results.isEmpty ? result : results.removeFirst()
    }
    func cancel() {}
}

@Suite struct TunnelControllerTests {
    let profile = Profile.presets(username: "u")[0]

    func make(helper: FakeHelper, auth: FakeAuth = FakeAuth(), healthy: @escaping @Sendable () -> Bool = { true }) -> TunnelController {
        var timing = TunnelController.Timing()
        timing.tick = 0.01
        timing.poll = 0.01
        timing.stopPoll = 0.001
        timing.backoffScale = 0.001
        return TunnelController(helper: helper, authenticator: auth, probe: healthy,
                                tunnelAddress: { "192.168.236.234" }, log: { _ in }, timing: timing)
    }

    func waitFor(_ controller: TunnelController, _ state: ConnectionState) async -> Bool {
        for _ in 0..<500 {
            if controller.status.state == state { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }

    @Test func connectsThenLogsOffOnDisconnect() async {
        let helper = FakeHelper()
        let controller = make(helper: helper)
        controller.connect(profile)
        #expect(await waitFor(controller, .connected))
        #expect(controller.status.tunnelAddress == "192.168.236.234")
        #expect(controller.status.summary.hasPrefix("connected"))
        controller.disconnect()
        #expect(await waitFor(controller, .disconnected))
        #expect(helper.logoffs == 1)
        #expect(controller.status.profileID == nil)
    }

    @Test func passesReconnectTimeoutToHelper() async {
        let helper = FakeHelper()
        let controller = make(helper: helper)
        controller.connect(profile, reconnectTimeout: 42)
        #expect(await waitFor(controller, .connected))
        #expect(helper.requests.first?.reconnectTimeout == 42)
        controller.shutdown()
    }

    @Test func rejectedLoginNeedsUser() async {
        let auth = FakeAuth()
        auth.result = .needsUser("rejected")
        let controller = make(helper: FakeHelper(), auth: auth)
        controller.connect(profile)
        #expect(await waitFor(controller, .needsUserAction))
        #expect(controller.status.message == "rejected")
    }

    @Test func offlineStartKeepsTryingForPasswordProfiles() async {
        let auth = FakeAuth()
        auth.results = [.retryLater, .retryLater]
        let controller = make(helper: FakeHelper(), auth: auth)
        controller.connect(profile)
        #expect(await waitFor(controller, .connected))
        #expect(auth.calls == 3)
        controller.shutdown()
    }

    @Test func firstOfflineRetryActuallyWaits() async {
        let auth = FakeAuth()
        auth.result = .retryLater
        var timing = TunnelController.Timing()
        timing.backoffScale = 0.1
        let controller = TunnelController(helper: FakeHelper(), authenticator: auth, probe: { true },
                                          tunnelAddress: { nil }, log: { _ in }, timing: timing)
        controller.connect(profile)
        try? await Task.sleep(nanoseconds: 250_000_000)
        #expect(auth.calls == 1)
        controller.shutdown()
    }

    @Test func offlineStartFailsForSSO() async {
        let auth = FakeAuth()
        auth.result = .retryLater
        let controller = make(helper: FakeHelper(), auth: auth)
        controller.connect(Profile.presets(username: "u")[1])
        #expect(await waitFor(controller, .failed))
        #expect(auth.calls == 1)
    }

    @Test func disconnectEndsWaitingForNetwork() async {
        let auth = FakeAuth()
        auth.result = .retryLater
        let controller = make(helper: FakeHelper(), auth: auth)
        controller.connect(profile)
        for _ in 0..<500 where auth.calls < 2 { try? await Task.sleep(nanoseconds: 2_000_000) }
        controller.disconnect()
        #expect(await waitFor(controller, .disconnected))
    }

    @Test func missingHelperFails() async {
        let helper = FakeHelper()
        helper.failConnect = true
        let controller = make(helper: helper)
        controller.connect(profile)
        #expect(await waitFor(controller, .failed))
    }

    @Test func networkChangeStartsFreshTunnelKeepingSession() async {
        let helper = FakeHelper()
        let controller = make(helper: helper)
        controller.connect(profile)
        #expect(await waitFor(controller, .connected))
        let since = controller.status.connectedSince
        controller.networkChanged()
        for _ in 0..<500 where helper.requests.count < 2 { try? await Task.sleep(nanoseconds: 5_000_000) }
        #expect(helper.requests.count == 2)
        #expect(helper.keeps == 1)
        #expect(helper.logoffs == 0)
        #expect(await waitFor(controller, .connected))
        #expect(controller.status.connectedSince == since)
        controller.shutdown()
    }

    @Test func crashedOpenconnectIsRestarted() async {
        let helper = FakeHelper()
        let controller = make(helper: helper)
        controller.connect(profile)
        #expect(await waitFor(controller, .connected))
        helper.kill()
        for _ in 0..<500 where helper.requests.count < 2 { try? await Task.sleep(nanoseconds: 5_000_000) }
        #expect(helper.requests.count == 2)
        controller.shutdown()
    }

    @Test func autoReconnectOffFails() async {
        let helper = FakeHelper()
        let controller = make(helper: helper)
        controller.autoReconnect = false
        controller.connect(profile)
        #expect(await waitFor(controller, .connected))
        helper.kill()
        #expect(await waitFor(controller, .failed))
        #expect(helper.requests.count == 1)
    }

    @Test func switchingProfilesLogsOffFirst() async {
        let helper = FakeHelper()
        let controller = make(helper: helper)
        let uhh = Profile.presets(username: "u")[1]
        controller.connect(profile)
        #expect(await waitFor(controller, .connected))
        controller.connect(uhh)
        for _ in 0..<500 where controller.status.profileID != "uhh" || controller.status.state != .connected {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(controller.status.profileID == "uhh")
        #expect(helper.logoffs == 1)
        controller.shutdown()
    }

    @Test func shutdownLogsOffSynchronously() async {
        let helper = FakeHelper()
        let controller = make(helper: helper)
        controller.connect(profile)
        #expect(await waitFor(controller, .connected))
        controller.shutdown()
        #expect(helper.logoffs == 1)
        #expect(controller.status.state == .disconnected)
    }
}

@Suite struct PhysicalPathTrackerTests {
    @Test func ignoresTunnelAndSystemInterfaces() {
        let addresses = ["en0": "192.168.178.109", "utun6": "192.168.236.234"]
        let identity = PhysicalPathTracker.identity(interfaces: ["utun6", "awdl0", "en0"]) { addresses[$0] }
        #expect(identity == "en0/192.168.178.109")
        #expect(PhysicalPathTracker.identity(interfaces: ["utun6"]) { addresses[$0] } == nil)
        #expect(PhysicalPathTracker.identity(interfaces: ["en0"]) { _ in nil } == nil)
    }

    @Test func tunnelComingUpIsNotAChange() {
        let tracker = TrackerBox()
        #expect(!tracker.update("en0/192.168.178.109"))
        #expect(!tracker.update("en0/192.168.178.109"))
    }

    @Test func hotspotOnSameInterfaceIsAChange() {
        let tracker = TrackerBox()
        _ = tracker.update("en0/192.168.178.109")
        #expect(tracker.update("en0/172.20.10.2"))
    }

    @Test func returningAfterALossIsAChange() {
        let tracker = TrackerBox()
        _ = tracker.update("en0/192.168.178.109")
        #expect(!tracker.update(nil))
        #expect(tracker.update("en0/192.168.178.109"))
    }

    @Test func firstValueIsOnlyABaseline() {
        let tracker = TrackerBox()
        #expect(!tracker.update("en7/10.0.0.2"))
        #expect(tracker.update("en0/192.168.178.109"))
    }
}

@Suite struct ControlSocketTests {
    func socketPath() -> String { "/tmp/labvpn-test-\(UUID().uuidString.prefix(8)).sock" }

    @Test func roundTripsRequestAndStatus() throws {
        let path = socketPath()
        let since = Date(timeIntervalSince1970: 1_800_000_000)
        let server = ControlServer(path: path) { request in
            ControlResponse(status: ControllerStatus(state: .connected, profileID: request.profile, connectedSince: since))
        }
        try server.start()
        defer { server.stop() }
        let reply = try ControlClient.send(ControlRequest(command: .connect, profile: "uhh"), path: path)
        #expect(reply.status.state == .connected)
        #expect(reply.status.profileID == "uhh")
        #expect(reply.status.connectedSince == since)
    }

    @Test func clientVanishingDoesNotKillTheServer() throws {
        let path = socketPath()
        let answered = DispatchSemaphore(value: 0)
        let server = ControlServer(path: path) { _ in
            usleep(200_000)
            answered.signal()
            return ControlResponse(status: ControllerStatus())
        }
        try server.start()
        defer { server.stop() }

        // Connect, send a request, and hang up before the reply.
        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(connected == 0)
        let request = Array(#"{"command":"status"}"#.utf8) + [0x0a]
        #expect(write(client, request, request.count) == request.count)
        close(client)

        #expect(answered.wait(timeout: .now() + 10) == .success)
        usleep(100_000)
        #expect(try ControlClient.send(ControlRequest(command: .status), path: path).status.state == .disconnected)
    }

    @Test func socketIsPrivateToTheUser() throws {
        let path = socketPath()
        let server = ControlServer(path: path) { _ in ControlResponse(status: ControllerStatus()) }
        try server.start()
        defer { server.stop() }
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func otherUserIsRefused() throws {
        let path = socketPath()
        let server = ControlServer(path: path, allowedUID: getuid() + 1) { _ in ControlResponse(status: ControllerStatus()) }
        try server.start()
        defer { server.stop() }
        #expect(throws: ControlError.badResponse) { try ControlClient.send(ControlRequest(command: .status), path: path) }
    }

    @Test func missingAppReportsNotRunning() {
        #expect(throws: ControlError.notRunning) {
            try ControlClient.send(ControlRequest(command: .status), path: "/tmp/labvpn-missing.sock")
        }
    }

    @Test func staleSocketFileDoesNotBlockStartup() throws {
        let path = socketPath()
        FileManager.default.createFile(atPath: path, contents: nil)
        let server = ControlServer(path: path) { _ in ControlResponse(status: ControllerStatus()) }
        try server.start()
        server.stop()
    }

    @Test func onlyConnectStartsTheApp() {
        #expect(ControlCommand.connect.startsApp)
        #expect(!ControlCommand.status.startsApp)
        #expect(!ControlCommand.disconnect.startsApp)
        #expect(!ControlCommand.reconnect.startsApp)
    }
}

@Suite struct StatusTextTests {
    @Test func summaryStartsWithConnectedOnlyWhenConnected() {
        let status = ControllerStatus(state: .connected, profileName: "ZBH VPN", tunnelAddress: "192.168.236.234")
        #expect(status.summary == "connected · ZBH VPN · 192.168.236.234")
        #expect(!ControllerStatus(state: .reconnecting).summary.hasPrefix("connected"))
        #expect(ControllerStatus(state: .fallbackDirect).summary == "reconnecting (direct)")
    }

    @Test func menuTitleShowsDuration() {
        let start = Date(timeIntervalSince1970: 0)
        let status = ControllerStatus(state: .connected, profileName: "ZBH VPN", tunnelAddress: "1.2.3.4", connectedSince: start)
        #expect(status.menuTitle(now: start.addingTimeInterval(720)) == "Connected · ZBH VPN · 12m · 1.2.3.4")
        #expect(status.menuTitle(now: start.addingTimeInterval(5400)) == "Connected · ZBH VPN · 1h 30m · 1.2.3.4")
    }
}

@Suite struct AppLogTests {
    @Test func redactsAndAppends() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + "/labvpn.log")
        let log = AppLog(url: url)
        log.write("hello")
        log.write("COOKIE=secret123")
        log.flush()
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("hello"))
        #expect(!text.contains("secret123"))
    }
}

/// `#expect` can't call a mutating method directly.
final class TrackerBox {
    private var tracker = PhysicalPathTracker()
    func update(_ identity: String?) -> Bool { tracker.update(identity) }
}

@Suite struct SignInTests {
    func script(_ body: String) throws -> String {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".sh")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    let uhh = Profile.presets(username: "u")[1]

    @Test func closedBrowserTimesOut() throws {
        let authenticator = Authenticator(executable: try script("exec sleep 30"), signInTimeout: 0.2) { _ in }
        guard case .needsUser(let message) = authenticator.authenticate(uhh, interactive: true) else {
            Issue.record("expected needsUser")
            return
        }
        #expect(message.contains("timed out"))
    }

    @Test func recoveryNeverOpensABrowser() throws {
        let marker = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).path
        let authenticator = Authenticator(executable: try script("touch \(marker)")) { _ in }
        guard case .needsUser = authenticator.authenticate(uhh, interactive: false) else {
            Issue.record("expected needsUser")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    @Test func cancelEndsSignIn() throws {
        let authenticator = Authenticator(executable: try script("exec sleep 30"), signInTimeout: 60) { _ in }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { authenticator.cancel() }
        #expect(authenticator.authenticate(uhh, interactive: true) == .retryLater)
    }

    @Test func expiredSessionIsMarked() async {
        let helper = FakeHelper()
        let auth = FakeAuth()
        auth.results = [.success(TunnelSupervisorTests.make("cookie")), .needsUser("expired")]
        var timing = TunnelController.Timing()
        timing.tick = 0.01
        timing.poll = 0.01
        timing.stopPoll = 0.001
        let controller = TunnelController(helper: helper, authenticator: auth, probe: { true },
                                          tunnelAddress: { nil }, log: { _ in }, timing: timing)
        controller.connect(uhh)
        for _ in 0..<500 where controller.status.state != .connected { try? await Task.sleep(nanoseconds: 5_000_000) }
        helper.rejectCookies = true
        helper.kill()
        for _ in 0..<500 where controller.status.state != .needsUserAction { try? await Task.sleep(nanoseconds: 5_000_000) }
        #expect(controller.status.sessionExpired)
        #expect(controller.status.profileID == "uhh")
    }
}

@Suite struct ProfileEditingTests {
    @Test func validatesGatewayAndFields() {
        var profile = Profile.presets(username: "u")[0]
        #expect(profile.validationError == nil)
        profile.host = "vpn.example.com/GROUP"
        #expect(profile.validationError == nil)
        for bad in ["", "https://vpn.example.com", "-bad.example.com", "a b.example.com"] {
            profile.host = bad
            #expect(profile.validationError != nil)
        }
        profile.host = "vpn.example.com"
        profile.username = " "
        #expect(profile.validationError != nil)
    }

    @Test func removingDefaultPicksAnother() {
        var store = ProfileStore(defaultProfile: "zbh", profiles: Profile.presets(username: "u"))
        store.remove(id: "zbh")
        #expect(store.defaultProfile == "uhh")
    }

    @Test func newIDsAreUnique() {
        let store = ProfileStore(defaultProfile: "zbh", profiles: Profile.presets(username: "u"))
        #expect(store.newProfileID(name: "ZBH") == "zbh2")
        #expect(store.newProfileID(name: "My Lab!") == "mylab")
        #expect(store.newProfileID(name: "äö") == "profile")
    }

    @Test func oldFileWithFingerprintStillLoads() throws {
        let json = #"{"defaultProfile":"zbh","profiles":[{"id":"zbh","name":"Z","host":"a.uni-hamburg.de","username":"u","auth":"password","forceFullTunnel":true,"mtu":null,"pinnedFingerprint":null}]}"#
        #expect(try JSONDecoder().decode(ProfileStore.self, from: Data(json.utf8)).profiles.count == 1)
    }
}

@Suite struct SetupFileTests {
    @Test func exportHasNoUsername() throws {
        let store = ProfileStore(defaultProfile: "zbh", profiles: Profile.presets(username: "bax1234"))
        let text = String(decoding: try store.exportSetup(), as: UTF8.self)
        #expect(!text.contains("bax1234"))
        #expect(!text.contains("username"))
        #expect(text.contains("vpn2-aux2"))
    }

    @Test func importKeepsExistingUsernameAndDefault() throws {
        var source = ProfileStore(defaultProfile: "uhh", profiles: Profile.presets(username: "a"))
        source.upsert(Profile(id: "lab", name: "Lab", host: "lab.example.org", username: "a", auth: .password, mtu: 1347))
        var target = ProfileStore(defaultProfile: "zbh", profiles: [Profile.presets(username: "mine")[0]])
        target.settings.connectOnLaunch = false

        try target.importSetup(try source.exportSetup(), username: "mine2")
        #expect(target.profile(id: "zbh")?.username == "mine")
        #expect(target.profile(id: "lab")?.username == "mine2")
        #expect(target.profile(id: "lab")?.mtu == 1347)
        #expect(target.defaultProfile == "zbh")
        #expect(!target.settings.connectOnLaunch)
    }

    @Test func firstImportAdoptsTheFilesDefault() throws {
        let source = ProfileStore(defaultProfile: "uhh", profiles: Profile.presets(username: "a"))
        var target = ProfileStore(defaultProfile: "", profiles: [])
        try target.importSetup(try source.exportSetup(), username: "me")
        #expect(target.defaultProfile == "uhh")
        #expect(target.profiles.count == 2)
    }

    @Test func importSkipsInvalidGateways() throws {
        let json = #"{"defaultProfile":"x","profiles":[{"id":"x","name":"X","host":"--script=/tmp/x","auth":"password","forceFullTunnel":true}]}"#
        var store = ProfileStore(defaultProfile: "zbh", profiles: Profile.presets(username: "u"))
        try store.importSetup(Data(json.utf8), username: "u")
        #expect(store.profile(id: "x") == nil)
    }

    @Test func exampleSetupFileLoads() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "examples/uni-hamburg.labvpn")
        var store = ProfileStore(defaultProfile: "", profiles: [])
        try store.importSetup(try Data(contentsOf: url), username: "me")
        #expect(store.defaultProfile == "zbh")
        #expect(store.profile(id: "uhh")?.auth == .browserSSO)
    }

    @Test func badFileThrows() {
        var store = ProfileStore(defaultProfile: "zbh", profiles: [])
        #expect(throws: (any Error).self) { try store.importSetup(Data("nope".utf8), username: "u") }
    }
}

@Suite struct DiagnosticsTests {
    @Test func containsNoKennungOrCookie() {
        let store = ProfileStore(defaultProfile: "zbh", profiles: Profile.presets(username: "bax1234"))
        let log = "POST for bax1234\nCOOKIE=topsecret\nwebvpn=abc123; path=/\nConnected"
        let files = Diagnostics.files(store: store, log: log, manifest: "OpenConnect v9.21", appVersion: "0.2.0") { path, _ in
            "output of \(path) for bax1234"
        }
        let everything = files.values.joined(separator: "\n")
        #expect(!everything.contains("bax1234"))
        #expect(!everything.contains("topsecret"))
        #expect(!everything.contains("abc123"))
        #expect(everything.contains("<kennung>"))
        #expect(Set(files.keys) == ["labvpn.log", "version.txt", "routes.txt", "dns.txt", "profiles.json"])
    }

    @Test func writesAZip() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".zip")
        try Diagnostics.writeZip(["a.txt": "hello"], to: url)
        let listing = Diagnostics.runTool("/usr/bin/unzip", ["-l", url.path])
        #expect(listing.contains("labvpn-diagnostics/a.txt"))
    }
}

/// Sample profiles for tests. The app ships none; see examples/uni-hamburg.labvpn.
extension Profile {
    static func presets(username: String) -> [Profile] {
        [
            Profile(id: "zbh", name: "ZBH VPN", host: "vpn2-aux2.rrz.uni-hamburg.de/VPNZBH", username: username, auth: .password),
            Profile(id: "uhh", name: "UHH VPN", host: "vpn.rrz.uni-hamburg.de", username: username, auth: .browserSSO),
        ]
    }
}
