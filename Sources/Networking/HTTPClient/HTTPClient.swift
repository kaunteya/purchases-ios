//
//  Copyright RevenueCat Inc. All Rights Reserved.
//
//  Licensed under the MIT License (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//      https://opensource.org/licenses/MIT
//
//  HTTPClient.swift
//
//  Created by César de la Vega on 7/22/21.

import Foundation

// swiftlint:disable file_length

class HTTPClient {

    typealias RequestHeaders = HTTPRequest.Headers
    typealias ResponseHeaders = HTTPResponse<HTTPEmptyResponseBody>.Headers
    typealias Completion<Value: HTTPResponseBody> = (HTTPResponse<Value>.Result) -> Void

    let systemInfo: SystemInfo
    let timeout: TimeInterval
    let apiKey: String
    let authHeaders: RequestHeaders

    private let session: URLSession
    private let state: Atomic<State> = .init(.initial)
    private let eTagManager: ETagManager
    private let dnsChecker: DNSCheckerType.Type
    private let signing: SigningType.Type

    init(apiKey: String,
         systemInfo: SystemInfo,
         eTagManager: ETagManager,
         dnsChecker: DNSCheckerType.Type = DNSChecker.self,
         signing: SigningType.Type = Signing.self,
         requestTimeout: TimeInterval = Configuration.networkTimeoutDefault) {
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 1
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = requestTimeout
        self.session = URLSession(configuration: config,
                                  delegate: RedirectLoggerSessionDelegate(),
                                  delegateQueue: nil)
        self.systemInfo = systemInfo
        self.eTagManager = eTagManager
        self.dnsChecker = dnsChecker
        self.signing = signing
        self.timeout = requestTimeout
        self.apiKey = apiKey
        self.authHeaders = HTTPClient.authorizationHeader(withAPIKey: apiKey)
    }

    /// - Parameter verificationMode: if `nil`, this will default to `SystemInfo.responseVerificationMode`
    func perform<Value: HTTPResponseBody>(
        _ request: HTTPRequest,
        with verificationMode: Signing.ResponseVerificationMode? = nil,
        completionHandler: Completion<Value>?
    ) {
        #if DEBUG
        guard !self.systemInfo.dangerousSettings.internalSettings.forceServerErrors else {
            completionHandler?(
                .failure(.errorResponse(Self.serverErrorResponse, .internalServerError))
            )
            return
        }
        #endif

        self.perform(request: .init(httpRequest: request,
                                    authHeaders: self.authHeaders,
                                    verificationMode: verificationMode ?? self.systemInfo.responseVerificationMode,
                                    completionHandler: completionHandler))
    }

    func clearCaches() {
        self.eTagManager.clearCaches()
    }

    var signatureVerificationEnabled: Bool {
        return self.systemInfo.responseVerificationMode.isEnabled
    }

}

extension HTTPClient {

    static func authorizationHeader(withAPIKey apiKey: String) -> RequestHeaders {
        return [RequestHeader.authorization.rawValue: "Bearer \(apiKey)"]
    }

    static func nonceHeader(with data: Data) -> RequestHeaders {
        return [RequestHeader.nonce.rawValue: data.base64EncodedString()]
    }

    enum RequestHeader: String {

        case authorization = "Authorization"
        case location = "Location"
        case nonce = "X-Nonce"
        case eTag = "X-RevenueCat-ETag"
        case eTagValidationTime = "X-RC-Last-Refresh-Time"

    }

    enum ResponseHeader: String {

        case eTag = "X-RevenueCat-ETag"
        case signature = "X-Signature"
        case requestDate = "X-RevenueCat-Request-Time"

    }

}

// @unchecked because:
// - Class is not `final` (it's mocked). This implicitly makes subclasses `Sendable` even if they're not thread-safe.
extension HTTPClient: @unchecked Sendable {}

// MARK: - Private

private extension HTTPClient {

    struct State {
        var queuedRequests: [Request]
        var currentSerialRequest: Request?

        static let initial: Self = .init(queuedRequests: [], currentSerialRequest: nil)
    }

    struct Request: CustomStringConvertible {

        var httpRequest: HTTPRequest
        var headers: HTTPClient.RequestHeaders
        var verificationMode: Signing.ResponseVerificationMode
        var completionHandler: HTTPClient.Completion<Data>?
        var retried: Bool = false

        init<Value: HTTPResponseBody>(httpRequest: HTTPRequest,
                                      authHeaders: HTTPClient.RequestHeaders,
                                      verificationMode: Signing.ResponseVerificationMode,
                                      completionHandler: HTTPClient.Completion<Value>?) {
            self.httpRequest = httpRequest.requestAddingNonceIfRequired(with: verificationMode)
            self.headers = self.httpRequest.headers(with: authHeaders)
            self.verificationMode = verificationMode

            if let completionHandler = completionHandler {
                self.completionHandler = { result in
                    completionHandler(result.parseResponse())
                }
            } else {
                self.completionHandler = nil
            }
        }

        var method: HTTPRequest.Method { self.httpRequest.method }
        var path: String { self.httpRequest.path.description }

        func adding(defaultHeaders: HTTPClient.RequestHeaders) -> Self {
            var copy = self
            copy.headers = defaultHeaders.merging(self.headers)

            return copy
        }

        func retriedRequest() -> Self {
            var copy = self
            copy.retried = true

            return copy
        }

        var description: String {
            """
            <\(type(of: self)): httpMethod=\(self.method.httpMethod)
            path=\(self.path)
            headers=\(self.headers.description )
            retried=\(self.retried)
            >
            """
        }
    }

}

private extension HTTPClient {

    var defaultHeaders: [String: String] {
        var headers: [String: String] = [
            "content-type": "application/json",
            "X-Version": SystemInfo.frameworkVersion,
            "X-Platform": SystemInfo.platformHeader,
            "X-Platform-Version": SystemInfo.systemVersion,
            "X-Platform-Flavor": systemInfo.platformFlavor,
            "X-Client-Version": SystemInfo.appVersion,
            "X-Client-Build-Version": SystemInfo.buildVersion,
            "X-Client-Bundle-ID": SystemInfo.bundleIdentifier,
            "X-StoreKit2-Enabled": "\(self.systemInfo.storeKit2Setting.isEnabledAndAvailable)",
            "X-Observer-Mode-Enabled": "\(self.systemInfo.observerMode)",
            "X-Is-Sandbox": "\(self.systemInfo.isSandbox)"
        ]

        if let platformFlavorVersion = self.systemInfo.platformFlavorVersion {
            headers["X-Platform-Flavor-Version"] = platformFlavorVersion
        }

        if let idfv = systemInfo.identifierForVendor {
            headers["X-Apple-Device-Identifier"] = idfv
        }
        return headers
    }

    static let serverErrorResponse: ErrorResponse = .init(code: .internalServerError,
                                                          originalCode: BackendErrorCode.unknownBackendError.rawValue)

    func perform(request: Request) {
        if !request.retried {
            let requestEnqueued: Bool = self.state.modify {
                if $0.currentSerialRequest != nil {
                    Logger.debug(Strings.network.serial_request_queued(httpMethod: request.method.httpMethod,
                                                                       path: request.path,
                                                                       queuedRequestsCount: $0.queuedRequests.count))

                    $0.queuedRequests.append(request)
                    return true
                } else {
                    Logger.debug(Strings.network.starting_request(httpMethod: request.method.httpMethod,
                                                                  path: request.path))
                    $0.currentSerialRequest = request
                    return false
                }
            }

            guard !requestEnqueued else { return }
        }

        self.start(request: request)
    }

    /// - Returns: `nil` if the request must be retried
    func parse(urlResponse: URLResponse?,
               request: Request,
               urlRequest: URLRequest,
               data: Data?,
               error networkError: Error?) -> HTTPResponse<Data>.Result? {
        if let networkError = networkError {
            return .failure(NetworkError(networkError, dnsChecker: self.dnsChecker))
        }

        guard let httpURLResponse = urlResponse as? HTTPURLResponse else {
            return .failure(.unexpectedResponse(urlResponse))
        }

        /// - Returns `nil` if status code is 304, since the response will be empty
        /// and fetched from the eTag.
        func dataIfAvailable(_ statusCode: HTTPStatusCode) -> Data? {
            if statusCode == .notModified {
                return nil
            } else {
                return data
            }
        }

        let statusCode = HTTPStatusCode(rawValue: httpURLResponse.statusCode)

        return Result
            .success(dataIfAvailable(statusCode))
            .mapToResponse(response: httpURLResponse,
                           request: request.httpRequest,
                           signing: self.signing,
                           verificationMode: request.verificationMode)
            .map { (response) -> HTTPResponse<Data>? in
                guard let cachedResponse = self.eTagManager.httpResultFromCacheOrBackend(
                    with: response,
                    request: urlRequest,
                    retried: request.retried
                ) else {
                    return nil
                }

                return cachedResponse
                    .copy(with: .from(cache: cachedResponse.verificationResult,
                                      response: response.verificationResult))
            }
            .asOptionalResult?
            .convertUnsuccessfulResponseToError()
    }

    func handle(urlResponse: URLResponse?,
                request: Request,
                urlRequest: URLRequest,
                data: Data?,
                error networkError: Error?) {
        let response = self.parse(
            urlResponse: urlResponse,
            request: request,
            urlRequest: urlRequest,
            data: data,
            error: networkError
        )

        if let response = response {
            switch response {
            case let .success(response):
                Logger.debug(Strings.network.api_request_completed(request.httpRequest, httpCode: response.statusCode))
            case let .failure(error):
                Logger.debug(Strings.network.api_request_failed(request.httpRequest, error: error))
            }

            request.completionHandler?(response)
        } else {
            Logger.debug(Strings.network.retrying_request(httpMethod: request.method.httpMethod,
                                                          path: request.path))

            self.state.modify {
                $0.queuedRequests.insert(request.retriedRequest(), at: 0)
            }
        }

        self.beginNextRequest()
    }

    func beginNextRequest() {
        let nextRequest: Request? = self.state.modify {
            Logger.debug(Strings.network.serial_request_done(httpMethod: $0.currentSerialRequest?.method.httpMethod,
                                                             path: $0.currentSerialRequest?.path,
                                                             queuedRequestsCount: $0.queuedRequests.count))
            $0.currentSerialRequest = $0.queuedRequests.popFirst()

            return $0.currentSerialRequest
        }

        if let nextRequest = nextRequest {
            Logger.debug(Strings.network.starting_next_request(request: nextRequest.description))
            self.start(request: nextRequest)
        }
    }

    func start(request: Request) {
        let urlRequest = self.convert(request: request.adding(defaultHeaders: self.defaultHeaders))

        guard let urlRequest = urlRequest else {
            Logger.error("Could not create request to \(request.path)")

            request.completionHandler?(
                .failure(.unableToCreateRequest(request.httpRequest.path))
            )
            return
        }

        Logger.debug(Strings.network.api_request_started(request.httpRequest))

        let task = self.session.dataTask(with: urlRequest) { (data, urlResponse, error) -> Void in
            self.handle(urlResponse: urlResponse,
                        request: request,
                        urlRequest: urlRequest,
                        data: data,
                        error: error)
        }
        task.resume()
    }

    func convert(request: Request) -> URLRequest? {
        guard let requestURL = request.httpRequest.path.url else {
            return nil
        }

        var urlRequest = URLRequest(url: requestURL)
        urlRequest.httpMethod = request.method.httpMethod
        urlRequest.allHTTPHeaderFields = self.headers(for: request, urlRequest: urlRequest)

        do {
            urlRequest.httpBody = try request.httpRequest.requestBody?.asData()
        } catch {
            Logger.error(Strings.network.creating_json_error(error: error.localizedDescription))
            return nil
        }

        return urlRequest
    }

    private func headers(for request: Request, urlRequest: URLRequest) -> HTTPClient.RequestHeaders {
        if request.httpRequest.path.shouldSendEtag {
            let eTagHeader = self.eTagManager.eTagHeader(
                for: urlRequest,
                withSignatureVerification: request.httpRequest.nonce != nil,
                refreshETag: request.retried
            )
            return request.headers.merging(eTagHeader)
        } else {
            return request.headers
        }
    }

}

// MARK: - Extensions

extension HTTPRequest {

    func requestAddingNonceIfRequired(
        with verificationMode: Signing.ResponseVerificationMode
    ) -> HTTPRequest {
        var result = self

        if result.nonce == nil,
           result.path.supportsSignatureValidation,
           verificationMode.isEnabled,
           #available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.2, *) {
            result.addRandomNonce()
        }

        return result
    }

    func headers(with authHeaders: HTTPClient.RequestHeaders) -> HTTPClient.RequestHeaders {
        var result: HTTPClient.RequestHeaders = [:]

        if self.path.authenticated {
            result += authHeaders
        }

        if let nonce = self.nonce {
            result += HTTPClient.nonceHeader(with: nonce)
        }

        return result
    }

}

extension HTTPRequest.Path {

    var url: URL? {
        return URL(string: self.relativePath, relativeTo: SystemInfo.serverHostURL)
    }

    var relativePath: String {
        return "\(Self.pathPrefix)/\(self.description)"
    }

    private static let pathPrefix: String = "/v1"

}

private extension Encodable {

    func asData() throws -> Data {
        return try JSONEncoder.default.encode(self)
    }

}

private extension NetworkError {

    /// Creates a `NetworkError` from any request `Error`.
    init(_ error: Error, dnsChecker: DNSCheckerType.Type) {
        if let blockedError = dnsChecker.errorWithBlockedHostFromError(error) {
            Logger.error(blockedError.description)
            self = blockedError
        } else {
            let nsError = error as NSError

            switch (nsError.domain, nsError.code) {
            case (NSURLErrorDomain, NSURLErrorNotConnectedToInternet):
                self = .offlineConnection()
            default:
                self = .networkError(error)
            }
        }
    }

}

extension Result where Success == HTTPResponse<Data>, Failure == NetworkError {

    // Converts an unsuccessful response into a `Result.failure`
    fileprivate func convertUnsuccessfulResponseToError() -> Self {
        return self.flatMap { response in
            response.statusCode.isSuccessfulResponse
            ? .success(response)
            : .failure(
                .errorResponse(
                    ErrorResponse.from(response.body),
                    response.statusCode
                )
            )
        }
    }

    // Parses a `Result<HTTPResponse<Data>>` to `Result<HTTPResponse<Value>>`
    func parseResponse<Value: HTTPResponseBody>() -> HTTPResponse<Value>.Result {
        return self.flatMap { response in          // Convert the `Result` type
            Result<HTTPResponse<Value>, Error> {   // Create a new `Result<Value>`
                try response.mapBody { data in     // Convert the body of `HTTPResponse<Data>` from `Data` -> `Value`
                    try Value.create(with: data)   // Decode `Data` into `Value`
                }
                .copyWithNewRequestDate()         // Update request date for 304 responses
            }
            // Convert decoding errors into `NetworkError.decoding`
            .mapError { NetworkError.decoding($0, response.body) }
        }
    }

}

extension HTTPResponse {

    fileprivate func copyWithNewRequestDate() -> Self {
        // Update request time from server unless it failed verification.
        guard self.verificationResult != .failed, let requestDate = self.requestDate else { return self }

        return self.mapBody {
            return $0.copy(with: requestDate)
        }
    }

}
