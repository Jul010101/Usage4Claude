//
//  CodexAccountUsageFetcher.swift
//  Usage4Claude
//
//  Explicit-account Codex usage fetcher for the multi-account overview
//  (feat/multi-account-overview). Unlike CodexAPIService, this never reads
//  UserSettings.shared / the current Codex account — every call takes an
//  `Account` value directly, so polling account B never mutates or depends
//  on which Codex account is "current". Supports both cookie-session and
//  OAuth accounts, mirroring CodexAPIService's own two-step auth flow
//  (credential → accessToken → usage) but scoped per explicit account id.
//
//  Unlike ClaudeAccountUsageFetcher (whose cookie path talks directly to
//  the usage endpoint with no token exchange), Codex's cookie path *also*
//  needs a token-exchange step (POST/GET /api/auth/session → accessToken),
//  so both credential kinds here share one per-account OAuthTokenCache and
//  a single unified 401 cache-clear/retry — this mirrors CodexAPIService's
//  structure more closely than ClaudeAccountUsageFetcher's split cookie/
//  OAuth paths, while preserving ClaudeAccountUsageFetcher's core
//  guarantees: explicit `Account` in, no current-account mutation, UUID-
//  targeted rotated-credential writeback, ephemeral no-cookie-storage
//  session.
//
//  Cancellation is intentionally propagated as-is (not folded into
//  `.networkError`) so a caller cancelling in-flight polling for one
//  account never gets misreported as a network failure; callers that
//  surface a typed `UsageError` (e.g. DataRefreshManager.codexUsageError)
//  are responsible for normalizing any non-`UsageError` (including
//  cancellation) to `.networkError` for display purposes.

import Foundation
import OSLog

@MainActor
final class CodexAccountUsageFetcher {
    static let shared = CodexAccountUsageFetcher()

    private var oauthCaches: [UUID: OAuthTokenCache] = [:]
    /// Newest known credential (session-token or "rt." refresh_token) per
    /// account id, updated every time a token exchange completes (rotated
    /// or not). Lets a same-call 401 retry (and any later call using a
    /// possibly-stale `Account` snapshot) use the freshest credential
    /// instead of the one that was just invalidated by rotation.
    private var latestRefreshTokens: [UUID: String] = [:]
    private let baseURL = "https://chatgpt.com"

    /// 主动刷新窗口：距过期不足20分钟时触发重新拉取（与 CodexAPIService 一致）
    private static let tokenRefreshMargin: TimeInterval = 20 * 60

    private let session: URLSession = {
        // Every request supplies credentials for one explicit account. An
        // ephemeral session with no cookie storage prevents Set-Cookie values
        // from one account being replayed on another account's request.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    /// Fetches Codex usage for `account`, routing to the cookie-session or
    /// OAuth path based on the credential format — same detection
    /// `CodexAPIService.isOAuthRefreshToken` uses for the current account.
    func fetchUsage(for account: Account) async -> Result<CodexUsageData, Error> {
        guard !account.sessionKey.isEmpty else {
            return .failure(UsageError.noCredentials)
        }
        return await fetchUsage(accountId: account.id, credential: account.sessionKey, retryOnUnauthorized: true)
    }

    private func fetchUsage(accountId: UUID, credential: String, retryOnUnauthorized: Bool) async -> Result<CodexUsageData, Error> {
        let accessTokenResult = await fetchAccessToken(accountId: accountId, credential: credential)
        switch accessTokenResult {
        case .failure(let error):
            return .failure(error)
        case .success(let accessToken):
            let result = await fetchWhamUsageData(accessToken: accessToken)
            if case .failure(let error) = result, case UsageError.unauthorized = error, retryOnUnauthorized {
                // Cached accessToken was rejected: clear and retry exactly once.
                // `fetchAccessToken` may have already rotated the credential
                // during the attempt above (updating `latestRefreshTokens`), so
                // the retry must re-read it here rather than reuse `credential`
                // — retrying with a pre-rotation credential would itself be rejected.
                await oauthCache(for: accountId).clear()
                let retryCredential = latestRefreshTokens[accountId] ?? credential
                return await fetchUsage(accountId: accountId, credential: retryCredential, retryOnUnauthorized: false)
            }
            return result
        }
    }

    // MARK: - Step 1: credential → accessToken (cached per account)

    private func oauthCache(for accountId: UUID) -> OAuthTokenCache {
        if let existing = oauthCaches[accountId] { return existing }
        let created = OAuthTokenCache()
        oauthCaches[accountId] = created
        return created
    }

    private func fetchAccessToken(accountId: UUID, credential: String) async -> Result<String, Error> {
        let cache = oauthCache(for: accountId)
        let effectiveCredential = latestRefreshTokens[accountId] ?? credential
        do {
            let accessToken = try await cache.accessToken(
                refreshToken: effectiveCredential,
                margin: Self.tokenRefreshMargin
            ) { [weak self] token in
                guard let self else { throw UsageError.networkError }
                if CodexAPIService.isOAuthRefreshToken(token) {
                    return try await self.refreshOAuthTokens(accountId: accountId, refreshToken: token)
                }
                return try await self.fetchSessionTokens(accountId: accountId, sessionToken: token)
            }
            return .success(accessToken)
        } catch {
            return .failure(error)
        }
    }

    /// cookie 账户：GET /api/auth/session（session-token Cookie，仅携带此账户自身的 token）
    /// 若响应通过 Set-Cookie 轮换了 session-token，仅从该响应头解析、按 UUID 静默写回，
    /// 绝不读取 HTTPCookieStorage.shared（会跨账户串扰）。
    private func fetchSessionTokens(accountId: UUID, sessionToken: String) async throws -> OAuthTokenCache.Tokens {
        guard let url = URL(string: "\(baseURL)/api/auth/session") else {
            throw UsageError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.assumesHTTP3Capable = false
        CodexAPIHeaderBuilder.applySessionHeaders(to: &request, sessionToken: sessionToken)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            Logger.api.debug("Account overview Codex session network error: \(error.localizedDescription)")
            throw Self.mapTransportError(error)
        }

        if let jsonString = String(data: data, encoding: .utf8),
           jsonString.contains("<!DOCTYPE html>") || jsonString.contains("<html") {
            throw UsageError.cloudflareBlocked
        }

        var effectiveSessionToken = sessionToken
        if let httpResponse = response as? HTTPURLResponse {
            switch httpResponse.statusCode {
            case 200...299:
                break
            case 401, 403:
                throw UsageError.unauthorized
            case 429:
                throw UsageError.rateLimited
            default:
                throw UsageError.httpError(statusCode: httpResponse.statusCode)
            }

            // Capture any rotated session token exclusively from this response's
            // own Set-Cookie headers (pure header parsing, no shared storage).
            let setCookieHeaders = httpResponse.allHeaderFields
                .filter { ($0.key as? String)?.lowercased() == "set-cookie" }
                .compactMap { $0.value as? String }
            if let newToken = Self.extractSessionToken(fromSetCookieHeaders: setCookieHeaders),
               newToken != sessionToken {
                effectiveSessionToken = newToken
                Logger.api.notice("Account overview Codex session: 检测到新 session-token，按账户 ID 静默写回")
                await MainActor.run {
                    UserSettings.shared.silentlyUpdateCodexSessionToken(newToken, forAccountId: accountId)
                }
            }
        }

        let decoder = JSONDecoder()
        do {
            let sessionResponse = try decoder.decode(CodexSessionResponse.self, from: data)
            guard let accessToken = sessionResponse.accessToken, !accessToken.isEmpty else {
                throw UsageError.sessionExpired
            }
            let expiry = jwtExpiry(from: accessToken) ?? Date().addingTimeInterval(30 * 60)
            latestRefreshTokens[accountId] = effectiveSessionToken
            return OAuthTokenCache.Tokens(accessToken: accessToken, refreshToken: effectiveSessionToken, expiresAt: expiry)
        } catch let error as UsageError {
            throw error
        } catch {
            Logger.api.debug("Account overview Codex session decode error: \(error.localizedDescription)")
            throw UsageError.decodingError
        }
    }

    /// OAuth 账户：用 refresh_token 向 auth.openai.com 换取 access_token（仅走网络端点，
    /// 不复用 CodexTokenRefreshCoordinator / CodexSilentRefreshCoordinator 等当前账户专用协调器）。
    /// refresh_token 轮换时按 UUID 静默写回账户存储。
    private func refreshOAuthTokens(accountId: UUID, refreshToken: String) async throws -> OAuthTokenCache.Tokens {
        let tokens = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CodexOAuthTokens, Error>) in
            CodexOAuthService.refresh(refreshToken: refreshToken) { result in
                continuation.resume(with: result)
            }
        }

        let newRefresh = tokens.refreshToken.isEmpty ? refreshToken : tokens.refreshToken
        latestRefreshTokens[accountId] = newRefresh
        if newRefresh != refreshToken {
            await MainActor.run {
                UserSettings.shared.silentlyUpdateCodexSessionToken(newRefresh, forAccountId: accountId)
            }
        }

        let expiry = jwtExpiry(from: tokens.accessToken) ?? Date().addingTimeInterval(30 * 60)
        return OAuthTokenCache.Tokens(accessToken: tokens.accessToken, refreshToken: newRefresh, expiresAt: expiry)
    }

    // MARK: - Step 2: accessToken → usage

    private func fetchWhamUsageData(accessToken: String) async -> Result<CodexUsageData, Error> {
        guard let url = URL(string: "\(baseURL)/backend-api/wham/usage") else {
            return .failure(UsageError.invalidURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.assumesHTTP3Capable = false
        CodexAPIHeaderBuilder.applyUsageHeaders(to: &request, accessToken: accessToken)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            Logger.api.debug("Account overview Codex usage network error: \(error.localizedDescription)")
            return .failure(Self.mapTransportError(error))
        }

        if let jsonString = String(data: data, encoding: .utf8),
           jsonString.contains("<!DOCTYPE html>") || jsonString.contains("<html") {
            return .failure(UsageError.cloudflareBlocked)
        }

        if let httpResponse = response as? HTTPURLResponse {
            switch httpResponse.statusCode {
            case 200...299:
                break
            case 401, 403:
                return .failure(UsageError.unauthorized)
            case 429:
                return .failure(UsageError.rateLimited)
            default:
                return .failure(UsageError.httpError(statusCode: httpResponse.statusCode))
            }
        }

        let decoder = JSONDecoder()
        do {
            let usageResponse = try decoder.decode(CodexUsageResponse.self, from: data)
            return .success(usageResponse.toCodexUsageData())
        } catch {
            Logger.api.debug("Account overview Codex usage decode error: \(error.localizedDescription)")
            return .failure(UsageError.decodingError)
        }
    }

    // MARK: - Helpers

    /// Parses raw Set-Cookie header strings (from one HTTPURLResponse) into
    /// HTTPCookie values using pure, storage-free parsing, then reuses
    /// CodexWebLoginCoordinator's existing session-token extraction (handles
    /// the standard name plus next-auth's chunked `.0`/`.1`/... cookie names).
    private static func extractSessionToken(fromSetCookieHeaders headers: [String]) -> String? {
        guard !headers.isEmpty, let url = URL(string: "https://chatgpt.com") else { return nil }
        let cookies = headers.flatMap { headerValue in
            HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": headerValue], for: url)
        }
        return CodexWebLoginCoordinator.extractSessionToken(from: cookies)
    }

    /// Preserves cancellation as a distinct, non-`UsageError` error rather than
    /// folding it into `.networkError`; every other transport failure maps to
    /// `.networkError`. Callers that need a typed `UsageError` for display
    /// (e.g. `DataRefreshManager.codexUsageError`) normalize any non-`UsageError`
    /// — including a propagated cancellation — to `.networkError` themselves.
    private static func mapTransportError(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if let urlError = error as? URLError, urlError.code == .cancelled { return error }
        return UsageError.networkError
    }
}
