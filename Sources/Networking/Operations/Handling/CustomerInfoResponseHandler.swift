//
//  Copyright RevenueCat Inc. All Rights Reserved.
//
//  Licensed under the MIT License (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//      https://opensource.org/licenses/MIT
//
//  CustomerInfoResponseHandler.swift
//
//  Created by Joshua Liebowitz on 11/18/21.

import Foundation

class CustomerInfoResponseHandler {

    init() { }

    func handle(customerInfoResponse response: HTTPResponse<Response>.Result,
                completion: CustomerAPI.CustomerInfoResponseHandler) {
        let result: Result<CustomerInfo, BackendError> = response
            .map { response in
                // If the response was successful we always want to return the `CustomerInfo`.
                if !response.body.errorResponse.attributeErrors.isEmpty {
                    // If there are any, log attribute errors.
                    // Creating the error implicitly logs it.
                    _ = response.body.errorResponse.asBackendError(with: response.statusCode)
                }

                return response.body.customerInfo.copy(with: response.verificationResult)
            }
            .mapError(BackendError.networkError)

        completion(result)
    }

}

extension CustomerInfoResponseHandler {

    struct Response: HTTPResponseBody {

        var customerInfo: CustomerInfo
        var errorResponse: ErrorResponse

        static func create(with data: Data) throws -> Self {
            return .init(customerInfo: try CustomerInfo.create(with: data),
                         errorResponse: ErrorResponse.from(data))
        }

        func copy(with newRequestDate: Date) -> Self {
            var copy = self
            copy.customerInfo = copy.customerInfo.copy(with: newRequestDate)

            return copy
        }

    }

}
