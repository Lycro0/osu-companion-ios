import Foundation
import Network

/// Tiny one-shot HTTP listener on 127.0.0.1 that captures the OAuth redirect
/// (http://127.0.0.1:42069/callback?code=...&state=...).
final class LoopbackServer {
    private var listener: NWListener?
    private var finished = false

    func start(port: UInt16, onResult: @escaping (_ query: [URLQueryItem]) -> Void) throws {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        guard let p = NWEndpoint.Port(rawValue: port) else { return }
        let l = try NWListener(using: params, on: p)
        l.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .main)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                guard let self, let data, let req = String(data: data, encoding: .utf8) else {
                    conn.cancel(); return
                }
                let line = req.components(separatedBy: "\r\n").first ?? ""
                let parts = line.split(separator: " ")
                guard parts.count >= 2,
                      let comps = URLComponents(string: "http://127.0.0.1" + String(parts[1])),
                      comps.path == "/callback" else {
                    Self.respond(conn, status: "404 Not Found", body: "Not found")
                    return
                }
                Self.respond(conn, status: "200 OK",
                             body: "<html><body style='font-family:-apple-system;text-align:center;padding:48px'><h2>Signed in</h2><p>You can close this window and return to osu! Companion.</p></body></html>")
                if !self.finished {
                    self.finished = true
                    onResult(comps.queryItems ?? [])
                }
            }
        }
        l.start(queue: .main)
        listener = l
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private static func respond(_ conn: NWConnection, status: String, body: String) {
        let bytes = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + bytes, completion: .contentProcessed { _ in conn.cancel() })
    }
}
