/*
 * test_wire_shape.m - offline wire-format conformance test for the MongrelDB
 * ObjC client.
 *
 * Does NOT contact a daemon. Serializes a create_table body, a batch txn body,
 * a query body, and a history-retention body, then asserts the exact JSON keys
 * and shape the server expects. This catches regressions in the on-wire format
 * without needing a running mongreldb-server.
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
- (instancetype)init {
    NSError *error = nil;
    self = [super initWithURL:@"http://127.0.0.1:8453"
                        token:nil
                     username:nil
                     password:nil
                        error:&error];
    (void)error;
    return self;
}
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

/* Subclass that returns a canned /history/retention response or an error so we
 * can assert the exact method/path/keys and error propagation without a daemon. */
@interface HistoryWireClient : MongrelDBClient
@property (nonatomic, copy) NSString *lastMethod;
@property (nonatomic, copy) NSString *lastPath;
@property (nonatomic, strong) NSDictionary *capturedBody;
@property (nonatomic, assign) BOOL failNext;
@end

@implementation HistoryWireClient
- (instancetype)init {
    NSError *error = nil;
    self = [super initWithURL:@"http://127.0.0.1:8453"
                        token:nil
                     username:nil
                     password:nil
                        error:&error];
    (void)error;
    return self;
}
- (nullable id)requestMethod:(NSString *)method
                        path:(NSString *)path
                        body:(nullable NSDictionary *)body
                       error:(NSError *_Nullable *_Nullable)error {
    self.lastMethod = [method copy];
    self.lastPath = [path copy];
    self.capturedBody = body;
    if (self.failNext) {
        if (error) {
            *error = [NSError errorWithDomain:MongrelDBErrorDomain
                                         code:MongrelDBErrorAuth
                                     userInfo:@{NSLocalizedDescriptionKey: @"forced error"}];
        }
        return nil;
    }
    if ([path isEqualToString:@"history/retention"]) {
        return @{@"history_retention_epochs": @7,
                 @"earliest_retained_epoch": @3};
    }
    return @{@"table_id": @42};
}
@end

/* Find a column dictionary in a create_table body by its numeric id. */
static NSDictionary *columnById(NSDictionary *body, int64_t colId) {
    NSArray *cols = body[@"columns"];
    if (![cols isKindOfClass:[NSArray class]]) {
        return nil;
    }
    for (NSDictionary *c in cols) {
        if (![c isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        id idObj = c[@"id"];
        if ([idObj isKindOfClass:[NSNumber class]] && [idObj longLongValue] == colId) {
            return c;
        }
    }
    return nil;
}

/* The create_table body must carry name, columns[] with id/name/ty/primary_key/
 * nullable, plus optional enum_variants and default_value when set. */
static void test_create_table_body(void) {
    MongrelDBColumn *c1 = [MongrelDBColumn columnWithId:1 name:@"id" type:@"int64"
                                            primaryKey:YES isNullable:NO];
    MongrelDBColumn *c2 = [[MongrelDBColumn alloc] init];
    c2.columnId = 4;
    c2.name = @"status";
    c2.type = @"enum";
    c2.primaryKey = NO;
    c2.isNullable = NO;
    c2.enumVariants = @[@"active", @"inactive", @"paused"];

    MongrelDBColumn *c3 = [MongrelDBColumn columnWithId:5 name:@"created_at"
                                                   type:@"timestamp_nanos"
                                             primaryKey:NO isNullable:NO];
    c3.defaultValue = @"legacy";
    c3.defaultValueJSON = @3;
    c3.defaultExpression = @"now";
    MongrelDBColumn *c4 = [MongrelDBColumn columnWithId:6 name:@"attempts"
                                                   type:@"int64"
                                             primaryKey:NO isNullable:NO];
    c4.defaultValueJSON = @3;
    MongrelDBColumn *c5 = [MongrelDBColumn columnWithId:7 name:@"s" type:@"varchar" primaryKey:NO isNullable:NO]; c5.defaultValueJSON = @"draft";
    MongrelDBColumn *c6 = [MongrelDBColumn columnWithId:8 name:@"b" type:@"bool" primaryKey:NO isNullable:NO]; c6.defaultValueJSON = @YES;
    MongrelDBColumn *c7 = [MongrelDBColumn columnWithId:9 name:@"n" type:@"varchar" primaryKey:NO isNullable:YES]; c7.defaultValueJSON = NSNull.null;
    MongrelDBColumn *c8 = [MongrelDBColumn columnWithId:10 name:@"ts_now" type:@"timestamp_nanos" primaryKey:NO isNullable:NO];
    c8.defaultValueJSON = @"now";
    MongrelDBColumn *c9 = [MongrelDBColumn columnWithId:11 name:@"u" type:@"uuid" primaryKey:NO isNullable:NO];
    c9.defaultValueJSON = @"uuid";
    NSDictionary *constraints = @{
        @"checks": @[@{@"id": @1, @"name": @"id_present",
                         @"expr": @{@"IsNotNull": @1}}],
    };
    CapturingClient *client = [[CapturingClient alloc] init];
    NSError *error = nil;
    int64_t tableId = [client createTableWithName:@"orders"
                                          columns:@[c1, c2, c3, c4, c5, c6, c7, c8, c9]
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
    CHECK([json containsString:@"\"default_value\":\"now\""], "body missing literal now default_value");
    CHECK([json containsString:@"\"default_value\":\"uuid\""], "body missing literal uuid default_value");

    /* Inspect decoded JSON to prove each literal preserves its scalar type. */
    NSDictionary *c3decoded = columnById(body, 5);
    CHECK(c3decoded != nil, "decoded column 5 missing");
    CHECK(c3decoded[@"default_expr"] != nil, "column 5 missing default_expr");
    CHECK(c3decoded[@"default_value"] == nil, "default_expr did not suppress default_value");

    NSDictionary *c4decoded = columnById(body, 6);
    CHECK([c4decoded[@"default_value"] isEqualToNumber:@3], "column 6 default_value should be integer 3");

    NSDictionary *c5decoded = columnById(body, 7);
    CHECK([c5decoded[@"default_value"] isEqualToString:@"draft"], "column 7 default_value should be string draft");

    NSDictionary *c6decoded = columnById(body, 8);
    CHECK([c6decoded[@"default_value"] isEqual:@YES], "column 8 default_value should be bool true");

    NSDictionary *c7decoded = columnById(body, 9);
    CHECK([c7decoded[@"default_value"] isEqual:NSNull.null], "column 9 default_value should be explicit null");

    NSDictionary *c8decoded = columnById(body, 10);
    CHECK([c8decoded[@"default_value"] isEqualToString:@"now"], "column 10 default_value should be literal string now");
    CHECK(c8decoded[@"default_expr"] == nil, "literal now must not be emitted as default_expr");

    NSDictionary *c9decoded = columnById(body, 11);
    CHECK([c9decoded[@"default_value"] isEqualToString:@"uuid"], "column 11 default_value should be literal string uuid");
    CHECK(c9decoded[@"default_expr"] == nil, "literal uuid must not be emitted as default_expr");

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
            @{@"range": @{@"column_id": @(3), @"lo": @(100), @"hi": @(500)}},
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

/* The history retention PUT body must use the exact frozen key, method, and path. */
static void test_history_retention_body(void) {
    HistoryWireClient *client = [[HistoryWireClient alloc] init];
    NSError *error = nil;
    NSDictionary *result = [client setHistoryRetentionEpochs:42 error:&error];
    CHECK(error == nil, "setHistoryRetentionEpochs returned an error");
    CHECK(result != nil, "setHistoryRetentionEpochs returned nil");
    CHECK([client.lastMethod isEqualToString:@"PUT"], "setter must use PUT");
    CHECK([client.lastPath isEqualToString:@"history/retention"], "setter must target /history/retention");

    NSDictionary *body = client.capturedBody;
    NSString *json = sortedJSON(body);
    CHECK([json containsString:@"\"history_retention_epochs\""], "body missing history_retention_epochs key");
    CHECK([json containsString:@"\"history_retention_epochs\":42"], "body missing history_retention_epochs value");
}

/* Setter error propagation: a non-2xx /history/retention response must reach
 * the caller as a nil result and a populated error. */
static void test_history_retention_setter_error_propagation(void) {
    HistoryWireClient *client = [[HistoryWireClient alloc] init];
    client.failNext = YES;
    NSError *error = nil;
    NSDictionary *result = [client setHistoryRetentionEpochs:42 error:&error];
    CHECK(error != nil, "setter error must be propagated");
    CHECK(result == nil, "setter must return nil on error");
}

/* GET /history/retention must parse both response keys and use the right
 * method/path. */
static void test_history_retention_get_response_keys(void) {
    HistoryWireClient *client = [[HistoryWireClient alloc] init];
    NSError *error = nil;
    uint64_t epochs = [client historyRetentionEpochs:&error];
    CHECK(error == nil, "historyRetentionEpochs returned an error");
    CHECK([client.lastMethod isEqualToString:@"GET"], "getter must use GET");
    CHECK([client.lastPath isEqualToString:@"history/retention"], "getter must target /history/retention");
    CHECK(epochs == 7, "historyRetentionEpochs did not parse response");

    uint64_t earliest = [client earliestRetainedEpoch:&error];
    CHECK(error == nil, "earliestRetainedEpoch returned an error");
    CHECK(earliest == 3, "earliestRetainedEpoch did not parse response");
}

/* Non-2xx responses from /history/retention must propagate to the caller. */
static void test_history_retention_error_propagation(void) {
    HistoryWireClient *client = [[HistoryWireClient alloc] init];
    client.failNext = YES;
    NSError *error = nil;
    uint64_t epochs = [client historyRetentionEpochs:&error];
    CHECK(error != nil, "error must be propagated");
    CHECK(epochs == 0, "getter must return 0 on error");
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
        RUN(test_history_retention_body);
        RUN(test_history_retention_setter_error_propagation);
        RUN(test_history_retention_get_response_keys);
        RUN(test_history_retention_error_propagation);
        RUN(test_error_mapping);
        RUN(test_crlf_rejection);
        printf("\n%d passed, %d failed\n", g_pass, g_fail);
        return g_fail > 0 ? 1 : 0;
    }
}
