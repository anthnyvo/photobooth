import Foundation

/// Auth client for the shared ShutterGlow backend — the same Supabase
/// project the web dashboard (shutterglow-web) signs into, so an operator's
/// dashboard account works unchanged on the iPad. Talks to Supabase's REST
/// endpoints directly over URLSession rather than pulling in the
/// supabase-swift SDK: this is a Swift Playgrounds package built only via
/// CI with no way to debug a dependency-resolution failure locally, so
/// staying pure-Foundation trades a little convenience for a lot fewer
/// moving parts to go wrong in a build that only fails hours later.
public struct AuthSession: Codable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let userId: String
    public let email: String
    public let expiresAt: Date
}

public enum SupabaseAuthError: Error, LocalizedError {
    case invalidCredentials
    case network

    public var errorDescription: String? {
        switch self {
        case .invalidCredentials: "Wrong email or password."
        case .network: "Couldn't reach the server — check your connection."
        }
    }
}

public final class SupabaseAuth: @unchecked Sendable {
    public static let shared = SupabaseAuth()

    // Anon key is meant to be embedded client-side — same key the web
    // dashboard ships in its NEXT_PUBLIC_ bundle. Row Level Security, not
    // this key, is what actually restricts access to an operator's own org.
    static let projectURL = URL(string: "https://sftbwrgiudkneasttqsd.supabase.co")!
    static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InNmdGJ3cmdpdWRrbmVhc3R0cXNkIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODM1Njg1MDQsImV4cCI6MjA5OTE0NDUwNH0.-n3T9IBymBBgNeg2NoTNWCUVbBXZKVXmgZL5eKpomT8"

    private static let sessionKey = "session"
    // Guarded by `lock`: read from sync callers (currentSession) and written
    // from concurrent refresh tasks, so a bare var here is a data race (UB).
    // The lock is only ever held for the assignment/read, never across an
    // await, so it can't deadlock the async paths below.
    private let lock = NSLock()
    private var _cachedSession: AuthSession?
    // Coalesces concurrent refreshes: without this, two guest taps hitting an
    // expired token both POST the same refresh_token, and Supabase's
    // refresh-token reuse detection revokes the whole token family — silently
    // signing the booth out mid-event.
    private var refreshTask: Task<AuthSession, Error>?

    private var cachedSession: AuthSession? {
        get { lock.lock(); defer { lock.unlock() }; return _cachedSession }
        set { lock.lock(); _cachedSession = newValue; lock.unlock() }
    }

    private init() {
        _cachedSession = Self.loadFromKeychain()
    }

    public func currentSession() -> AuthSession? {
        cachedSession
    }

    public func signIn(email: String, password: String) async throws -> AuthSession {
        let url = URL(string: "auth/v1/token?grant_type=password", relativeTo: Self.projectURL)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(Self.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["email": email, "password": password])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SupabaseAuthError.network
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SupabaseAuthError.invalidCredentials
        }
        let session = try JSONDecoder().decode(TokenResponse.self, from: data).asSession()
        cachedSession = session
        Self.saveToKeychain(session)
        return session
    }

    public func signOut() {
        cachedSession = nil
        KeychainStore.delete(key: Self.sessionKey)
    }

    /// The token to use right now — refreshes first if the cached one is at
    /// (or near) expiry. Silent: a refresh failure just returns nil, and
    /// callers treat "no valid session" as "stay on cached local data,"
    /// exactly the local-first behavior the venue-connectivity story needs.
    public func validSession() async -> AuthSession? {
        guard let session = cachedSession else { return nil }
        if session.expiresAt > Date().addingTimeInterval(60) {
            return session
        }
        return try? await coalescedRefresh()
    }

    /// Refreshes at most once even under concurrent callers: the first to
    /// arrive creates the refresh task, the rest await the same one. Re-checks
    /// the cached session under the lock first, so a caller that raced in just
    /// after a completed refresh reuses the fresh token instead of POSTing the
    /// now-rotated refresh_token (which would trip reuse detection).
    private func coalescedRefresh() async throws -> AuthSession {
        lock.lock()
        if let existing = refreshTask {
            lock.unlock()
            return try await existing.value
        }
        if let current = _cachedSession, current.expiresAt > Date().addingTimeInterval(60) {
            lock.unlock()
            return current
        }
        guard let stale = _cachedSession else {
            lock.unlock()
            throw SupabaseAuthError.network
        }
        let task = Task { try await self.performRefresh(stale) }
        refreshTask = task
        lock.unlock()

        defer {
            lock.lock()
            refreshTask = nil
            lock.unlock()
        }
        return try await task.value
    }

    private func performRefresh(_ session: AuthSession) async throws -> AuthSession {
        let url = URL(string: "auth/v1/token?grant_type=refresh_token", relativeTo: Self.projectURL)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(Self.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["refresh_token": session.refreshToken])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SupabaseAuthError.network
        }
        let refreshed = try JSONDecoder().decode(TokenResponse.self, from: data).asSession()
        cachedSession = refreshed
        Self.saveToKeychain(refreshed)
        return refreshed
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String
        let expires_in: Int
        let user: UserPayload

        struct UserPayload: Decodable {
            let id: String
            let email: String?
        }

        func asSession() -> AuthSession {
            AuthSession(
                accessToken: access_token,
                refreshToken: refresh_token,
                userId: user.id,
                email: user.email ?? "",
                expiresAt: Date().addingTimeInterval(TimeInterval(expires_in))
            )
        }
    }

    private static func saveToKeychain(_ session: AuthSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        KeychainStore.save(data, key: sessionKey)
    }

    private static func loadFromKeychain() -> AuthSession? {
        guard let data = KeychainStore.load(key: sessionKey) else { return nil }
        return try? JSONDecoder().decode(AuthSession.self, from: data)
    }
}
