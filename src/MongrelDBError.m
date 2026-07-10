/*
 * MongrelDBError.m - Typed error code constants for the MongrelDB Objective-C client.
 *
 * Licensing: MIT OR Apache-2.0.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 */

#import "MongrelDBError.h"

NSErrorDomain const MongrelDBErrorDomain = @"MongrelDBErrorDomain";

MongrelDBErrorCode MongrelDBErrorCodeForHTTP(NSInteger statusCode) {
    switch (statusCode) {
        case 401:
        case 403:
            return MongrelDBErrorAuth;
        case 404:
            return MongrelDBErrorNotFound;
        case 409:
            return MongrelDBErrorConflict;
        default:
            return MongrelDBErrorQuery;
    }
}
