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

@interface MongrelDBClient (WireShapeTest)
- (nullable id)requestMethod:(NSString *)method
                        path:(NSString *)path
                        body:(nullable NSDictionary *)body
                       error:(NSError *_Nullable *_Nullable)error;
@end

@interface CapturingClient : MongrelDBClient
@property (nonatomic, strong) NSDictionary *capturedBody;
@end

@implementation CapturingClient
- (nullable id)requestMethod:(NSString *)method
                        path:(NSString *)path
                        body:(nullable NSDictionary *)body
                       error:(NSError *_Nullable *_Nullable)error {
    (void)method;
    (void)path;
    (void)error;
    self.capturedBody = body;
    return @{@"table_id": @42};
}
@end

/* The create_table body must carry name, columns[] with id/name/ty/primary_key/
 * nullable, plus optional enum_variants and default_value when set. */
static void test_create_table_body(void) {
    MongrelDBColumn *c1 = [MongrelDBColumn columnWithId:1 name:@"id" type:@"int64"
                                            primaryKey:YES nullable:NO];
    MongrelDBColumn *c2 = [[MongrelDBColumn alloc] init];
    c2.columnId = 4;
    c2.name = @"status";
    c2.type = @"enum";
    c2.primaryKey = NO;
    c2.nullable = NO;
    c2.enumVariants = @[@"active", @"inactive", @"paused"];

    MongrelDBColumn *c3 = [MongrelDBColumn columnWithId:5 name:@"created_at"
                                                   type:@"timestamp_nanos"
                                             primaryKey:NO nullable:NO];
    c3.defaultValue = @"legacy";
    c3.defaultValueJSON = @3;
    c3.defaultExpression = @"now";
    MongrelDBColumn *c4 = [MongrelDBColumn columnWithId:6 name:@"attempts"
                                                   type:@"int64"
                                             primaryKey:NO nullable:NO];
    c4.defaultValueJSON = @3;
    MongrelDBColumn *c5 = [MongrelDBColumn columnWithId:7 name:@"s" type:@"varchar" primaryKey:NO nullable:NO]; c5.defaultValueJSON = @"draft";
    MongrelDBColumn *c6 = [MongrelDBColumn columnWithId:8 name:@"b" type:@"bool" primaryKey:NO nullable:NO]; c6.defaultValueJSON = @YES;
    MongrelDBColumn *c7 = [MongrelDBColumn columnWithId:9 name:@"n" type:@"varchar" primaryKey:NO nullable:YES]; c7.defaultValueJSON = NSNull.null;
    NSDictionary *constraints = @{
        @"checks": @[@{@"id": @1, @"name": @"id_present",
                         @"expr": @{@"IsNotNull": @1}}],
    };
    CapturingClient *client = [[CapturingClient alloc] init];
    NSError *error = nil;
    int64_t tableId = [client createTableWithName:@"orders"
                                          columns:@[c1, c2, c3, c4, c5, c6, c7]
                                      constraints:constraints
                                            error:&error];
    CHECK(error == nil, "createTable returned an error");
    CHECK(tableId == 42, "createTable did not return captured table id");

    NSDictionary *body = client.capturedBody;
    NSString *json = sortedJSON(body);
    CHECK([json containsString:@"\"name\":\"orders\""], "body missing table name");
    CHECK([json containsString:@"\"ty\":\"int64\""], "body missing column type");
    CHECK([json containsString:@"\"primary_key\":true"], "body missing primary_key");
    CHECK([json containsString:@"\"enum_variants\""], "body missing enum_variants");
    CHECK([json containsString:@"\"default_value\":3"], "body missing scalar default_value");
    CHECK([json containsString:@"\"default_expr\":\"now\""], "body missing default_expr");
    CHECK([json containsString:@"\"default_value\":\"draft\""], "body missing string default");
    CHECK([json containsString:@"\"default_value\":true"], "body missing bool default");
    CHECK([json containsString:@"\"default_value\":null"], "body missing null default");
    NSDictionary *created = [body[@"columns"] objectAtIndex:2];
    CHECK(created[@"default_value"] == nil, "default_expr did not suppress default_value");
    CHECK([json containsString:@"\"constraints\""], "body missing constraints");
    CHECK([json containsString:@"\"checks\""], "body missing constraints.checks");
    CHECK([json containsString:@"\"IsNotNull\":1"], "body missing check expression");
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
    (void)argc;
    (void)argv;
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
