import Foundation
import KultrDLCore
import Observation

enum MessageKind {
    case info, success, warning, error
}

struct UiMessage: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let kind: MessageKind
    let long: Bool
}

/** Toast-style messages from anywhere in the app, shown over the page. */
@MainActor
@Observable
final class UiMessages {
    private(set) var current: UiMessage?

    @ObservationIgnored private var hideTask: Task<Void, Never>?

    func show(_ text: String, _ kind: MessageKind = .info, long: Bool = false) {
        let message = UiMessage(text: text, kind: kind, long: long)
        current = message
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: long ? 7_000_000_000 : 3_500_000_000)
            guard !Task.isCancelled, let self, self.current?.id == message.id else { return }
            self.current = nil
        }
    }

    func error(_ text: String) { show(text, .error, long: true) }

    func success(_ text: String) { show(text, .success) }

    func dismiss() {
        hideTask?.cancel()
        current = nil
    }
}

/** A sentence for an error, as people should read it. */
func describe(_ error: Error) -> String {
    if let e = error as? KultrError { return e.message }
    if let e = error as? RemoteError { return e.errorDescription ?? "The server refused." }
    if let e = error as? UntrustedServerError { return e.reason.message }
    if let e = error as? YouTubeRefusal { return e.errorDescription ?? "YouTube refused." }
    if let e = error as? HttpError {
        switch e.code {
        case 403: return "\(e.host) refused (403)."
        case 404: return "Not found on \(e.host)."
        case 429: return "\(e.host) asks to slow down (429). Try again in a minute."
        default: return "\(e.host) answered \(e.code)."
        }
    }
    if let e = error as? StreamForbidden { return e.errorDescription ?? "The stream was refused." }
    if let e = error as? URLError {
        switch e.code {
        case .notConnectedToInternet: return "The phone is offline."
        case .timedOut: return "The connection timed out."
        case .cannotFindHost, .dnsLookupFailed: return "Couldn't reach the site. Check the connection."
        case .cancelled: return "Cancelled."
        default: return e.localizedDescription
        }
    }
    if error is CancellationError { return "Cancelled." }
    let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    return text.isEmpty ? String(describing: error) : text
}
