import Foundation

/// Serves the guest application's loopback proxy through the existing NOW
/// control connection. The Python renderer is deliberately reachable only
/// inside this process boundary; the classic browser never sees its port.
@MainActor
final class WebWireService: NSObject {
    static let maximumResponseBytes = 512 * 1024
    static let chunkBytes = 2_048

    private struct ActiveRequest {
        let id: Int
        let task: Task<Void, Never>
    }

    private let model: WebBridgeModel
    private var active: [GuestKey: ActiveRequest] = [:]

    init(model: WebBridgeModel) {
        self.model = model
    }

    func serve(_ ask: GuestListener.WebAsk, on asker: Session) {
        switch ask {
        case .request(let request):
            start(request, on: asker)
        case .cancel(let request):
            cancel(request, on: asker)
        }
    }

    func sessionClosed(key: GuestKey?) {
        guard let key else { return }
        active.removeValue(forKey: key)?.task.cancel()
    }

    private func start(_ request: WebRequest, on asker: Session) {
        guard let key = asker.guestKey else { return }
        guard active[key] == nil else {
            end(request.id, code: "busy",
                reason: "Another browser request is still loading", on: asker)
            return
        }
        guard let endpoint = model.rendererEndpoint else {
            end(request.id, code: "unavailable",
                reason: "Start Web Proxy on this Mac first", on: asker)
            return
        }
        guard let url = Self.rendererURL(
            for: request, endpoint: endpoint, profile: model.profile,
            lens: model.lens, handlersEnabled: model.handlersEnabled
        ) else {
            end(request.id, code: "invalid",
                reason: "The browser sent an invalid address", on: asker)
            return
        }

        let task = Task { [weak self, weak asker] in
            defer {
                if self?.active[key]?.id == request.id {
                    self?.active[key] = nil
                }
            }
            do {
                var urlRequest = URLRequest(url: url)
                urlRequest.httpMethod = request.method
                urlRequest.timeoutInterval = 45
                let (data, response) = try await URLSession.shared.data(
                    for: urlRequest)
                try Task.checkCancellation()
                guard data.count <= Self.maximumResponseBytes else {
                    throw WebWireFault.tooLarge
                }
                guard let asker else { return }
                let http = response as? HTTPURLResponse
                asker.send(.webResponseBegin(WebResponseBegin(
                    id: request.id,
                    status: http?.statusCode ?? 502,
                    contentType: response.mimeType ?? "text/html",
                    bytes: data.count)))
                var seq = 0
                for offset in stride(from: 0, to: data.count,
                                     by: Self.chunkBytes) {
                    try Task.checkCancellation()
                    let end = min(offset + Self.chunkBytes, data.count)
                    asker.send(.webResponseChunk(WebResponseChunk(
                        id: request.id, seq: seq,
                        data: data[offset..<end].base64EncodedString())))
                    seq += 1
                }
                asker.send(.webResponseEnd(WebResponseEnd(
                    id: request.id, ok: true, code: nil, reason: nil)))
            } catch is CancellationError {
                asker?.send(.webResponseEnd(WebResponseEnd(
                    id: request.id, ok: false, code: "cancelled",
                    reason: "The browser request was cancelled")))
            } catch WebWireFault.tooLarge {
                if let asker {
                    self?.end(request.id, code: "too-large",
                        reason: "The translated page exceeded 512 KB", on: asker)
                }
            } catch {
                if let asker {
                    self?.end(request.id, code: "fetch-failed",
                        reason: "The host renderer could not load that page",
                        on: asker)
                }
            }
        }
        active[key] = ActiveRequest(id: request.id, task: task)
    }

    private func cancel(_ cancel: WebCancel, on asker: Session) {
        guard let key = asker.guestKey, let active = active[key],
              active.id == cancel.id else {
            end(cancel.id, code: "cancelled",
                reason: "That browser request is no longer running", on: asker)
            return
        }
        active.task.cancel()
    }

    private func end(_ id: Int, code: String, reason: String,
                     on asker: Session) {
        asker.send(.webResponseEnd(WebResponseEnd(
            id: id, ok: false, code: code, reason: reason)))
    }

    static func rendererURL(
        for request: WebRequest, endpoint: URL,
        profile: WebBrowserProfile, lens: WebRenderingLens,
        handlersEnabled: Bool
    ) -> URL? {
        guard request.method == "GET" || request.method == "HEAD",
              request.target.utf8.count <= 2_048 else { return nil }
        if request.target.hasPrefix("http://")
            || request.target.hasPrefix("https://") {
            var parts = URLComponents(
                url: endpoint.appendingPathComponent("go"),
                resolvingAgainstBaseURL: false)
            parts?.queryItems = [
                URLQueryItem(name: "u", value: request.target),
                URLQueryItem(name: "profile", value: profile.rawValue),
                URLQueryItem(name: "lens", value: lens.rawValue),
                URLQueryItem(name: "handlers",
                             value: handlersEnabled ? "on" : "off"),
            ]
            return parts?.url
        }
        guard request.target.hasPrefix("/"),
              !request.target.hasPrefix("//") else { return nil }
        return URL(string: request.target, relativeTo: endpoint)?.absoluteURL
    }
}

private enum WebWireFault: Error {
    case tooLarge
}
