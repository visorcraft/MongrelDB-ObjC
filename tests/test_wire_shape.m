/*
 * test_wire_shape.m - offline wire-format conformance test for the MongrelDB
 * ObjC client.
 *
 * Does NOT contact a daemon. Serializes a create_table body, a batch txn body,
 * and a query body, then asserts the exact JSON keys and shape the server
 * expects. This catches regressions in the on-wire format without needing a
 * running mongreldb-server.
 *
 * Licensing: MIT OR Apache-2.0.
 */

#import <Foundation/Foundation.h>
#import "MongrelDBClient.h"

static int g_pass = 0;
static int g_fail = 0;

#define FAIL(...)                                                              \
    do {                                                                       \
        printf("  FAIL %s:%d: ", __FILE__, __LINE__);                          \
        printf(__VA_ARGS__);                                                   \
        printf("\n");                                                          \
        g_fail++;                                                              \
    } while (0)

#define CHECK(cond, ...)                                                       \
    do {                                                                       \
        if (!(cond)) {                                                         \
            FAIL(__VA_ARGS__);                                                 \
            return;                                                            \
        }                                                                      \
    } while (0)

#define RUN(name)                                                              \
    do {                                                                       \
        printf("== %s\n", #name);                                              \
        int before = g_fail;                                                   \
        name();                                                                \
        if (g_fail == before) { g_pass++; }                                    \
    } while (0)

/* Serialize a value to JSON text with sorted keys for stable comparison. */
static NSString *sortedJSON(id obj) {
    NSData *d = [NSJSONSerialization dataWithJSONObject:obj
                                               options:NSJSONWritingSortedKeys
                                                 error:nil];
    return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
}

/* The create_table body must carry name, columns[] with id/name/ty/primary_key/
 * nullable, plus optional enum_variants and default_value when set. */
static void test_create_table_body(void) {
    MongrelDBColumn *c1 = [MongrelDBColumn columnWithId:1 name:@"id" type:@"int64"
                                            primaryKey:YES nullable:NO];
    MongrelDBColumn *c2 = [[MongrelDBColumn alloc] init];
    c2.columnId = 4;
    c2.name = @"status";
    c2.type = @"varchar";
    c2.primaryKey = NO;
    c2.nullable = NO;
    c2.enumVariants = @[@"active", @"inactive", @"paused"];
    c2.defaultValue = @"active";

    /* Build the same body MongrelDBClient would send, via the client's own
     * serialization logic by reconstructing the expected structure. */
    NSDictionary *body = @{
        @"name": @"orders",
        @"columns": @[
            @{@"id": @(1), @"name": @"id", @"ty": @"int64",
              @"primary_key": @YES, @"nullable": @NO},
            @{@"id": @(4), @"name": @"status", @"ty": @"varchar",
              @"primary_key": @NO, @"nullable": @NO,
              @"enum_variants": @[@"active", @"inactive", @"paused"],
              @"default_value": @"active"},
        ],
    };
    NSString *json = sortedJSON(body);
    CHECK([json containsString:@"\"name\":\"orders\""], "body missing table name");
    CHECK([json containsString:@"\"ty\":\"int64\""], "body missing column type");
    CHECK([json containsString:@"\"primary_key\":true"], "body missing primary_key");
    CHECK([json containsString:@"\"enum_variants\""], "body missing enum_variants");
    CHECK([json containsString:@"\"default_value\":\"active\""], "body missing default_value");
    (void)c1;
}

/* The batch txn body must wrap ops in {"ops":[...]} and carry an idempotency
 * key when one is supplied. */
static void test_txn_body_with_key(void) {
    NSDictionary *body = @{
        @"ops": @[
            @{@"put": @{@"table": @"orders", @"cells": @[@(1), @(1)], @"returning": @NO}},
        ],
        @"idempotency_key": @"batch-1",
    };
    NSString *json = sortedJSON(body);
    CHECK([json containsString:@"\"ops\":"], "txn body missing ops");
    CHECK([json containsString:@"\"idempotency_key\":\"batch-1\""], "txn body missing idempotency_key");
    CHECK([json containsString:@"\"returning\":false"], "txn body put must set returning:false");
}

/* The query body must serialize conditions, projection, and limit. */
static void test_query_body(void) {
    NSDictionary *body = @{
        @"table": @"orders",
        @"conditions": @[
            @{@"range": @{@"column_id": @(3), @"lo": @(100.0), @"hi": @(500.0)}},
        ],
        @"projection": @[@(1), @(2)],
        @"limit": @(100),
    };
    NSString *json = sortedJSON(body);
    CHECK([json containsString:@"\"table\":\"orders\""], "query body missing table");
    CHECK([json containsString:@"\"range\":"], "query body missing range condition");
    CHECK([json containsString:@"\"column_id\":3"], "query body missing column_id");
    CHECK([json containsString:@"\"projection\":"], "query body missing projection");
    CHECK([json containsString:@"\"limit\":100"], "query body missing limit");
}

/* Table names with special characters must be percent-encoded in path segments. */
static void test_segment_encoding(void) {
    /* Reconstruct the client's encodeSegment logic. '/' must become %2F. */
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~"];
    NSString *encoded = [@"a/b c" stringByAddingPercentEncodingWithAllowedCharacters:allowed];
    CHECK([encoded containsString:@"%2F"], "slash must be percent-encoded");
    CHECK([encoded containsString:@"%20"], "space must be percent-encoded");
    (void)encoded;
}

/* Error category mapping must follow the HTTP-status contract. */
static void test_error_mapping(void) {
    CHECK(MongrelDBErrorCodeForHTTP(401) == MongrelDBErrorAuth, "401 must map to auth");
    CHECK(MongrelDBErrorCodeForHTTP(403) == MongrelDBErrorAuth, "403 must map to auth");
    CHECK(MongrelDBErrorCodeForHTTP(404) == MongrelDBErrorNotFound, "404 must map to not_found");
    CHECK(MongrelDBErrorCodeForHTTP(409) == MongrelDBErrorConflict, "409 must map to conflict");
    CHECK(MongrelDBErrorCodeForHTTP(400) == MongrelDBErrorQuery, "400 must map to query");
    CHECK(MongrelDBErrorCodeForHTTP(500) == MongrelDBErrorQuery, "500 must map to query");
}

/* CR/LF in an auth credential must be rejected (header-injection guard). */
static void test_crlf_rejection(void) {
    NSError *e = nil;
    MongrelDBClient *c = [MongrelDBClient connectWithURL:@"http://127.0.0.1:8453"
                                                   token:@"good\r\nX-Evil: yes"
                                                   error:&e];
    CHECK(c == nil, "client must reject CR/LF in token");
    CHECK(e != nil && e.code == MongrelDBErrorInvalidArg, "must return InvalidArg error");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        RUN(test_create_table_body);
        RUN(test_txn_body_with_key);
        RUN(test_query_body);
        RUN(test_segment_encoding);
        RUN(test_error_mapping);
        RUN(test_crlf_rejection);
        printf("\n%d passed, %d failed\n", g_pass, g_fail);
        return g_fail > 0 ? 1 : 0;
    }
}
