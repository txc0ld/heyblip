import Foundation

/// Per-request trace ID plumbing. Attach `X-Trace-ID` to every outbound HTTP
/// request from the iOS client; both Workers (blip-auth, blip-relay) read it,
/// log it on every request line, and (today) tag Sentry events with it. A
/// tester can paste a session trace ID and John can grep `wrangler tail` /
/// Sentry / the in-app debug overlay for a single request across all three
/// systems. (BDEV-403)
extension URLRequest {
    /// Attach a freshly generated trace ID and return the value so the caller
    /// can log it on the same line as the request emission. Mutates `self`.
    mutating func attachTraceID(category: String) -> String {
        let traceID = DebugLogger.shared.nextTraceID()
        setValue(traceID, forHTTPHeaderField: "X-Trace-ID")
        DebugLogger.emit(category, "→ \(httpMethod ?? "GET") \(url?.path ?? "?") trace=\(traceID)")
        return traceID
    }
}
