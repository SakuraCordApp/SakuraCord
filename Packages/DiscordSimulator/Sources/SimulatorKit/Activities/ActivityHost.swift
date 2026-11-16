import Foundation
import Synchronization

/// Serves the simulator's own Activity as `{application_id}.discordsays.com`
/// (base port + 7). The redirect drops the host name, so the page finds its
/// application from the Discord proxy ticket in its launch URL. The page speaks
/// the Embedded App SDK's frame protocol to the client hosting it, lists who
/// is playing, and keeps a shared count through its own backend under
/// `/.proxy/`, the path Discord's proxy forwards to an Activity's server.
final class ActivityHost: Sendable {
    let world: World
    let log: SimulatorLog
    /// The Activity backend's state: a shared count per instance.
    private let counts = Mutex<[String: Int]>([:])

    init(world: World, log: SimulatorLog) {
        self.world = world
        self.log = log
    }

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/"):
            guard let ticket = request.query["discord_proxy_ticket"]?.first, let appID = await world.activityApplication(forTicket: ticket),
                  let name = await world.users[appID].map({ $0.globalName ?? $0.username })
            else { return notFound(request) }
            return .bytes(200, Data(Self.page(clientID: appID, name: name).utf8), contentType: "text/html; charset=utf-8")
        case ("GET", "/.proxy/api/count"), ("POST", "/.proxy/api/count"):
            let instance = request.query["instance"]?.first ?? ""
            let count = counts.withLock { counts in
                if request.method == "POST" { counts[instance, default: 0] += 1 }
                return counts[instance, default: 0]
            }
            return .json(200, .object(JSONObject([("count", .int(count))])))
        default:
            return notFound(request)
        }
    }

    private func notFound(_ request: HTTPRequest) -> HTTPResponse {
        log.error("activity", "UNKNOWN ACTIVITY PATH \(request.method) \(request.target)")
        return .bytes(404, Data("404: Not Found".utf8), contentType: "text/plain")
    }

    static func page(clientID: Snowflake, name: String) -> String {
        let title = name.replacingOccurrences(of: "<", with: "&lt;")
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>\(title)</title>
        <style>
        html,body{margin:0;height:100%;font:16px -apple-system,system-ui,sans-serif;color:#f4eef8;background:radial-gradient(circle at 30% 20%,#5b3a7a,#1d1430)}
        main{height:100%;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:18px}
        h1{margin:0;font-size:28px}#players{opacity:.8}button{font:inherit;font-size:22px;padding:14px 30px;border:0;border-radius:999px;
        background:#f5a3c7;color:#2a1838;cursor:pointer}#count{font-size:56px;font-weight:700}
        </style></head><body><main>
        <h1>\(title)</h1><div id="players">Connecting…</div><div id="count">0</div><button id="pass">Pass the petal</button>
        </main><script>
        const params = new URLSearchParams(location.search);
        const instance = params.get('instance_id') || 'solo';
        let nonce = 0;
        const pending = new Map();
        const send = (op, payload) => parent.postMessage([op, payload], '*');
        const command = (cmd, args = {}, evt) => new Promise(resolve => {
            const id = String(++nonce);
            pending.set(id, resolve);
            send(1, evt ? {cmd, args, evt, nonce: id} : {cmd, args, nonce: id});
        });
        const showPlayers = list => {
            const names = (list || []).map(p => p.global_name || p.username).filter(Boolean);
            document.getElementById('players').textContent = names.length ? 'Playing: ' + names.join(', ') : 'Waiting for players';
        };
        const showCount = async method => {
            const reply = await fetch('/.proxy/api/count?instance=' + encodeURIComponent(instance), {method});
            document.getElementById('count').textContent = (await reply.json()).count;
        };
        addEventListener('message', event => {
            const [op, payload] = Array.isArray(event.data) ? event.data : [];
            if (op !== 1 || !payload) return;
            if (payload.cmd === 'DISPATCH') {
                if (payload.evt === 'READY') {
                    command('SUBSCRIBE', {}, 'ACTIVITY_INSTANCE_PARTICIPANTS_UPDATE');
                    command('GET_INSTANCE_CONNECTED_PARTICIPANTS').then(data => showPlayers(data && data.participants));
                } else if (payload.evt === 'ACTIVITY_INSTANCE_PARTICIPANTS_UPDATE') {
                    showPlayers(payload.data && payload.data.participants);
                }
            } else if (pending.has(payload.nonce)) {
                pending.get(payload.nonce)(payload.data);
                pending.delete(payload.nonce);
            }
        });
        document.getElementById('pass').onclick = () => showCount('POST');
        setInterval(() => showCount('GET'), 2000);
        showCount('GET');
        send(0, {v: 1, encoding: 'json', client_id: '\(clientID)', frame_id: params.get('frame_id')});
        </script></body></html>
        """
    }
}
