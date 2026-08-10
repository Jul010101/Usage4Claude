//
//  ClaudeAccountUsageFetcher.swift
//  Usage4Claude
//
//  Explicit-account Claude usage fetcher for the multi-account overview
//  (feat/multi-account-overview). Unlike ClaudeAPIService, this never reads
//  UserSettings.shared / the current account — every call takes an `Account`
//  value directly, so polling account B never mutates or depends on which
//  account is "current". Supports both cookie-session and OAuth accounts,
//  reusing ClaudeAPIHeaderBuilder / UsageResponse / ClaudeOAuthService /
//  ClaudeOAuthConfig / OAuthTokenCache and the exact UsageError→
//  AccountUsageFailureReason mapping below.
//
//  Only fetches the mandatory main usage window; Extra Usage is intentionally
//  omitted here to keep this new polling path low-risk (see task scope).
//

import Foundation
import OSLog

// MARK: - UsageError → AccountUsageFailureReason mapping

extension AccountUsageFailureReason {
    /// Exhaustive 1:1 mirror of `UsageError` (Services/ClaudeAPIService.swift).
    /// Kept exhaustive on purpose: if `UsageError` gains/loses a case, this
    /// switch fails to compile, forcing the mirror to be updated in lockstep.
    init(_ usageError: UsageError) {
        switch usageError {
        case .noCredentials: self = .noCredentials
        case .unauthorized: self = .unauthorized
        case .sessionExpired: self = .sessionExpired
        case .rateLimited: self = .rateLimited
        case .networkError: self = .networkError
        case .cloudflareBlocked: self = .cloudflareBlocked
        case .httpError(let statusCode): self = .httpError(statusCode: statusCode)
        case .noData: self = .noData
        case .decodingError: self = .decodingError
        case .invalidURL: self = .invalidURL
        }
    }
}

// MARK: - Fetcher

/// Fetches Claude usage for an explicit `Account`, never touching
/// `UserSettings.shared.currentAccountId`. One `OAuthTokenCache` is kept per
/// account id so OAuth accounts don't share (or fight over) a single-flight
/// refresh slot with each other or with the current-account `ClaudeAPIService`.
@MainActor
final class ClaudeAccountUsageFetcher {
    static let shared = ClaudeAccountUsageFetcher()

    private var oauthCaches: [UUID: OAuthTokenCache] = [:]
    /// Newest known refresh_token per account id, updated every time
    /// `refreshOAuthTokens` completes an exchange (rotated or not). Lets a
    /// same-call 401 retry (and any later call using a possibly-stale
    /// `Account` snapshot) use the freshest token instead of the one that
    /// was just invalidated by rotation.
    private var latestRefreshTokens: [UUID: String] = [:]
    private let baseURL = "https://claude.ai/api/organizations"

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

    /// Fetches main usage for `account`, routing to the cookie-session or
    /// OAuth path based on the credential format — same detection
    /// `ClaudeAPIService.isOAuthRefreshToken` uses for the current account.
    func fetchUsage(for account: Account) async -> Result<UsageData, Error> {
        guard !account.sessionKey.isEmpty else {
            return .failure(UsageError.noCredentials)
        }
        if ClaudeAPIService.isOAuthRefreshToken(account.sessionKey) {
            return await fetchOAuthUsage(accountId: account.id, refreshToken: account.sessionKey)
        }
        guard !account.organizationId.isEmpty else {
            return .failure(UsageError.noCredentials)
        }
        return await fetchCookieUsage(organizationId: account.organizationId, sessionKey: account.sessionKey)
    }

    // MARK: - Cookie-session path

    private func fetchCookieUsage(organizationId: String, sessionKey: String) async -> Result<UsageData, Error> {
        let urlString = "\(baseURL)/\(organizationId)/usage"
        guard let url = URL(string: urlString) else {
            return .failure(UsageError.invalidURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.assumesHTTP3Capable = false
        ClaudeAPIHeaderBuilder.applyHeaders(to: &request, organizationId: organizationId, sessionKey: sessionKey)

        do {
            let (data, response) = try await session.data(for: request)
            return Self.decodeMainUsageResponse(data: data, response: response)
        } catch {
            Logger.api.debug("Account overview cookie fetch network error: \(error.localizedDescription)")
            return .failure(UsageError.networkError)
        }
    }

    /// Mirrors ClaudeAPIService.fetchMainUsage's HTML-detection, HTTP-status,
    /// and error-response handling so both call sites classify identically.
    private static func decodeMainUsageResponse(data: Data, response: URLResponse) -> Result<UsageData, Error> {
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
        if let errorResponse = try? decoder.decode(ErrorResponse.self, from: data),
           errorResponse.error.type == "permission_error" {
            return .failure(UsageError.sessionExpired)
        }

        do {
            let usageResponse = try decoder.decode(UsageResponse.self, from: data)
            return .success(usageResponse.toUsageData())
        } catch {
            return .failure(UsageError.decodingError)
        }
    }

    // MARK: - OAuth path

    private func oauthCache(for accountId: UUID) -> OAuthTokenCache {
        if let existing = oauthCaches[accountId] { return existing }
        let created = OAuthTokenCache()
        oauthCaches[accountId] = created
        return created
    }

    private func fetchOAuthUsage(accountId: UUID, refreshToken: String, retryOnUnauthorized: Bool = true) async -> Result<UsageData, Error> {
        let cache = oauthCache(for: accountId)
        // Reconcile against our own actor-local record: a caller may pass a
        // stale `Account.sessionKey` snapshot (e.g. taken before an earlier
        // rotation's MainActor write-back landed), so prefer the freshest
        // token we've actually observed for this account id.
        let effectiveRefreshToken = latestRefreshTokens[accountId] ?? refreshToken
        let accessToken: String
        do {
            accessToken = try await cache.accessToken(refreshToken: effectiveRefreshToken) { token in
                try await self.refreshOAuthTokens(accountId: accountId, refreshToken: token)
            }
        } catch {
            return .failure(error)
        }

        let result = await fetchOAuthUsageData(accessToken: accessToken)
        if case .failure(let error) = result, case UsageError.unauthorized = error, retryOnUnauthorized {
            // access_token expired: clear the cache and retry exactly once.
            // `refreshOAuthTokens` may have already rotated the refresh_token
            // during the attempt above (updating `latestRefreshTokens`), so the
            // retry must re-read it here rather than reuse `effectiveRefreshToken`
            // — retrying with a pre-rotation token would itself be rejected.
            await cache.clear()
            let retryToken = latestRefreshTokens[accountId] ?? effectiveRefreshToken
            return await fetchOAuthUsage(accountId: accountId, refreshToken: retryToken, retryOnUnauthorized: false)
        }
        return result
    }

    /// Exchanges refresh_token for access_token; on rotation, writes the new
    /// refresh_token back to the account by id (never the "current account"
    /// method — this account may not be the current one).
    private func refreshOAuthTokens(accountId: UUID, refreshToken: String) async throws -> OAuthTokenCache.Tokens {
        let tokens = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ClaudeOAuthTokens, Error>) in
            ClaudeOAuthService.refresh(refreshToken: refreshToken) { result in
                continuation.resume(with: result)
            }
        }

        let newRefresh = tokens.refreshToken.isEmpty ? refreshToken : tokens.refreshToken
        latestRefreshTokens[accountId] = newRefresh
        if newRefresh != refreshToken {
            await MainActor.run {
                UserSettings.shared.silentlyUpdateClaudeSessionToken(newRefresh, forAccountId: accountId)
            }
        }

        let expiry = tokens.expiresAt ?? Date().addingTimeInterval(30 * 60)
        return OAuthTokenCache.Tokens(accessToken: tokens.accessToken, refreshToken: newRefresh, expiresAt: expiry)
    }

    private func fetchOAuthUsageData(accessToken: String) async -> Result<UsageData, Error> {
        guard let url = URL(string: ClaudeOAuthConfig.usageURL) else {
            return .failure(UsageError.invalidURL)
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(ClaudeOAuthConfig.betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            Logger.api.error("Account overview OAuth usage network error: \(error.localizedDescription)")
            return .failure(UsageError.networkError)
        }

        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200...299:
                break
            case 401:
                return .failure(UsageError.unauthorized)
            case 429:
                return .failure(UsageError.rateLimited)
            default:
                return .failure(UsageError.httpError(statusCode: http.statusCode))
            }
        }

        let decoder = JSONDecoder()
        do {
            let baseResponse = try decoder.decode(UsageResponse.self, from: data)
            return .success(baseResponse.toUsageData())
        } catch {
            Logger.api.error("Account overview OAuth usage decode error: \(error.localizedDescription)")
            return .failure(UsageError.decodingError)
        }
    }
}
