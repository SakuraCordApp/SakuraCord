@testable import SimulatorKit
import Testing

/// The parity suite is the simulator's contract with the captured wire shapes.
@Suite(.serialized)
struct ParityTests {
    @Test func simulatorMatchesCapturedShapes() async {
        let report = await ParitySuite.run()
        #expect(report.passed, "\(report.summary)")
        #expect(report.checked.count > 30)
    }

    @Test(arguments: ["demo", "demo-large"])
    func generatedAccountsMatchCapturedShapes(scenario: String) async {
        let report = await ParitySuite.runWorld(scenario: scenario)
        #expect(report.passed, "\(report.summary)")
        #expect(report.checked.count > 10)
    }

    /// Voice, DAVE, Go Live, soundboard, calls and Activities on a generated server, not only the hand-written world.
    @Test func voiceFlowsMatchCapturedShapesOnAGeneratedServer() async {
        let report = await ParitySuite.runVoice(scenario: "demo")
        #expect(report.passed, "\(report.summary)")
        #expect(report.checked.count > 30)
    }

    /// Shapes are committed, so a captured account identifier must never survive as template text.
    @Test func routeTemplatesHideAccountIdentifiers() {
        #expect(RouteTemplate.template(method: "GET", path: "/api/v9/users/@me/connections/twitch/somename/access-token")
            == "GET /api/v9/users/@me/connections/twitch/{connection_id}/access-token")
        #expect(RouteTemplate.template(method: "GET", path: "/api/v9/users/@me/connections/spotify/4fk2q9zz81mxkq0p")
            == "GET /api/v9/users/@me/connections/spotify/{connection_id}")
        #expect(RouteTemplate.template(method: "GET", path: "/api/v9/applications/a1b2c3d4e5f6g7h8/assets")
            == "GET /api/v9/applications/{id}/assets")
        #expect(RouteTemplate.template(method: "POST", path: "/api/v9/applications/880218394199220334/activities/pc-id_31770/instances/1300000000000000000/leave")
            == "POST /api/v9/applications/{id}/activities/{id}/instances/{id}/leave")
        #expect(RouteTemplate.template(method: "GET", path: "/api/v9/users/@me/settings-proto/2")
            == "GET /api/v9/users/@me/settings-proto/2")
    }

    @Test func brokenResponseShapeFails() async {
        let target = "REST GET /api/v9/channels/{id}/messages"
        let report = await ParitySuite.run { subject, body in
            subject == target ? ParitySuite.dropFirstField(body) : body
        }
        #expect(!report.passed)
        #expect(report.failures.contains { $0.subject == target && $0.violation.kind == .missingField })
    }
}
