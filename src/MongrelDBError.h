/*
 * MongrelDBError.h - Typed error code constants for the MongrelDB Objective-C client.
 *
 * Every MongrelDBClient method that can fail returns an NSError whose domain is
 * MongrelDBErrorDomain and whose code is one of the MongrelDBErrorCode constants
 * below. The localized description carries the daemon's message when one was
 * supplied.
 *
 * The categories mirror the HTTP-status mapping used by the other official
 * clients: auth (401/403), not found (404), conflict (409), and everything else.
 *
 * Licensing: MIT OR Apache-2.0.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/* Error domain for all MongrelDBClient failures. */
FOUNDATION_EXPORT NSErrorDomain const MongrelDBErrorDomain;

/* Error codes. Mirrors the categorization of the other MongrelDB clients.
 * Uses NS_ENUM (rather than NS_ERROR_ENUM) because the codes are plain
 * integers applied to NSError via the separate MongrelDBErrorDomain constant;
 * NS_ERROR_ENUM's first argument must name a global error-domain constant,
 * which does not fit this layout. */
typedef NS_ENUM(NSInteger, MongrelDBErrorCode) {
    MongrelDBErrorAuth           = -1,  /* HTTP 401 or 403 */
    MongrelDBErrorNotFound       = -2,  /* HTTP 404 */
    MongrelDBErrorConflict       = -3,  /* HTTP 409 (unique/fk/check violation) */
    MongrelDBErrorQuery          = -4,  /* HTTP 400 or 5xx, malformed request */
    MongrelDBErrorNetwork        = -5,  /* transport failure */
    MongrelDBErrorJSON           = -6,  /* malformed JSON from the server */
    MongrelDBErrorInvalidArg     = -8,  /* nil or otherwise invalid argument */
};

/* Map an HTTP status code to the matching error category. Used by the request
 * helper when the daemon returns a non-2xx response. */
FOUNDATION_EXPORT MongrelDBErrorCode MongrelDBErrorCodeForHTTP(NSInteger statusCode);

NS_ASSUME_NONNULL_END
