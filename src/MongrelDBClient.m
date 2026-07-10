/*
 * MongrelDBClient.m - Objective-C (Apple Foundation) HTTP client for MongrelDB.
 *
 * Talks to a running mongreldb-server daemon's JSON API via NSURLSession. Uses
 * NSJSONSerialization for both encoding requests and decoding responses. All
 * table names in path segments are URL-encoded; CRLF is rejected in auth
 * credentials to prevent header injection.
 *
 * Licensing: MIT OR Apache-2.0.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 */

#import "MongrelDBClient.h"

/* ── Constants ─────────────────────────────────────────────────────────── */

NSString *const MongrelDBDefaultURL = @"http://127.0.0.1:8453";
const int64_t MongrelDBMaxResponseBytes = 268435456LL; /* 256 MB */

/* ── MongrelDBInputCell ────────────────────────────────────────────────── */

@implementation MongrelDBInputCell

+ (instancetype)cellWithColumnId:(int64_t)columnId value:(nullable MongrelDBValue)value {
    return [[self alloc] initWithColumnId:columnId value:value];
}

- (instancetype)initWithColumnId:(int64_t)columnId value:(nullable MongrelDBValue)value {
    self = [super init];
    if (self) {
        _columnId = columnId;
        _value = value ?: NSNull.null;
    }
    return self;
}

@end

/* ── MongrelDBColumn ───────────────────────────────────────────────────── */

@implementation MongrelDBColumn

+ (instancetype)columnWithId:(int64_t)columnId
                        name:(nullable NSString *)name
                        type:(nullable NSString *)type
                 primaryKey:(BOOL)primaryKey
                    nullable:(BOOL)nullable {
    MongrelDBColumn *c = [[self alloc] init];
    if (c) {
        c.columnId = columnId;
        c.name = [name copy];
        c.type = [type copy];
        c.primaryKey = primaryKey;
        c.nullable = nullable;
    }
    return c;
}

@end

/* ── MongrelDBCondition ────────────────────────────────────────────────── */

@implementation MongrelDBCondition
@end

/* ── MongrelDBClient ───────────────────────────────────────────────────── */

@interface MongrelDBClient ()
@property (nonatomic, copy) NSString *baseURL;
@property (nonatomic, copy, nullable) NSString *token;
@property (nonatomic, copy, nullable) NSString *username;
@property (nonatomic, copy, nullable) NSString *password;
@property (nonatomic, assign) NSTimeInterval timeout;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSLock *errorLock;
@property (nonatomic, copy) NSString *lastErrorStr;
/* Expand the flat `cells` array in one /kit/query row into a column-id-keyed
 * dictionary. */
- (NSDictionary *)decodeQueryRow:(id)raw;
@end

@implementation MongrelDBClient

/* ── Lifecycle ─────────────────────────────────────────────────────────── */

- (nullable instancetype)initWithURL:(NSString *)url
                               token:(nullable NSString *)token
                            username:(nullable NSString *)username
                            password:(nullable NSString *)password
                               error:(NSError *_Nullable *_Nullable)error {
    self = [super init];
    if (!self) {
        return nil;
    }

    /* Reject CR/LF in any auth credential: token/username/password are placed
     * verbatim into the Authorization header, so an embedded newline would
     * allow header injection (request splitting). Validate before use. */
    NSArray<NSString *> *creds = token ? @[token] :
        (username ? @[username, password ?: @""] : @[]);
    for (NSString *c in creds) {
        if ([c rangeOfCharacterFromSet:[NSCharacterSet characterSetWithRange:NSMakeRange('\r', 1)]].location != NSNotFound ||
            [c rangeOfCharacterFromSet:[NSCharacterSet characterSetWithRange:NSMakeRange('\n', 1)]].location != NSNotFound) {
            if (error) {
                *error = [NSError errorWithDomain:MongrelDBErrorDomain
                                             code:MongrelDBErrorInvalidArg
                                         userInfo:@{NSLocalizedDescriptionKey:
                                            @"auth credential must not contain CR or LF"}];
            }
            return nil;
        }
    }

    NSString *u = (url.length > 0) ? url : MongrelDBDefaultURL;
    /* Trim any trailing slash so path joining stays clean. */
    while ([u hasSuffix:@"/"] && u.length > 1) {
        u = [u substringToIndex:u.length - 1];
    }
    _baseURL = [u copy];
    _token = [token copy];
    _username = [username copy];
    _password = [password copy];
    _timeout = 30.0;
    _errorLock = [[NSLock alloc] init];
    _lastErrorStr = @"";

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    /* Never follow redirects: an Authorization header could follow a redirect
     * to an attacker-controlled host. */
    cfg.HTTPShouldSetCookies = NO;
    cfg.timeoutIntervalForRequest = 30.0;
    cfg.timeoutIntervalForResource = 60.0;
    cfg.URLCache = nil;
    _session = [NSURLSession sessionWithConfiguration:cfg];

    return self;
}

+ (nullable instancetype)connectWithURL:(nullable NSString *)url
                                  error:(NSError *_Nullable *_Nullable)error {
    return [[self alloc] initWithURL:url ?: @"" token:nil username:nil password:nil error:error];
}

+ (nullable instancetype)connectWithURL:(nullable NSString *)url
                                  token:(nullable NSString *)token
                                  error:(NSError *_Nullable *_Nullable)error {
    return [[self alloc] initWithURL:url ?: @"" token:token username:nil password:nil error:error];
}

+ (nullable instancetype)connectWithURL:(nullable NSString *)url
                               username:(nullable NSString *)username
                               password:(nullable NSString *)password
                                  error:(NSError *_Nullable *_Nullable)error {
    return [[self alloc] initWithURL:url ?: @"" token:nil username:username password:password error:error];
}

- (void)setTimeout:(NSTimeInterval)seconds {
    _timeout = seconds > 0 ? seconds : 30.0;
}

- (NSString *)lastError {
    [self.errorLock lock];
    NSString *e = [self.lastErrorStr copy];
    [self.errorLock unlock];
    return e ?: @"";
}

- (void)setLastErrorStrInternal:(NSString *)msg {
    [self.errorLock lock];
    _lastErrorStr = [msg copy];
    [self.errorLock unlock];
}

/* ── Internal request helper ───────────────────────────────────────────── */

/* Build a new NSError, stash its message as the last error, and return it. */
- (NSError *)makeError:(MongrelDBErrorCode)code message:(NSString *)message {
    [self setLastErrorStrInternal:message];
    return [NSError errorWithDomain:MongrelDBErrorDomain
                                code:code
                            userInfo:@{NSLocalizedDescriptionKey: message ?: @""}];
}

/* Percent-encode a single URL path segment so a table name containing '/',
 * '?', '#', or spaces cannot inject extra segments or break routing. */
+ (NSString *)encodeSegment:(NSString *)segment {
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~"];
    return [segment stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
}

/* Synchronous request helper. Returns the decoded JSON body (or nil for empty
 * bodies). Sets *error on failure. */
- (nullable id)requestMethod:(NSString *)method
                        path:(NSString *)path
                       body:(nullable NSDictionary *)body
                      error:(NSError *_Nullable *_Nullable)error {
    NSString *urlStr = [NSString stringWithFormat:@"%@/%@", self.baseURL, path];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) {
        if (error) {
            *error = [self makeError:MongrelDBErrorInvalidArg message:@"invalid URL"];
        }
        return nil;
    }

    NSMutableURLRequest *req = [[NSMutableURLRequest alloc] initWithURL:url];
    req.HTTPMethod = method;
    req.timeoutInterval = self.timeout;
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];

    /* Auth header. Token takes precedence over basic. */
    if (self.token.length > 0) {
        NSString *h = [NSString stringWithFormat:@"Bearer %@", self.token];
        [req setValue:h forHTTPHeaderField:@"Authorization"];
    } else if (self.username.length > 0) {
        NSString *creds = [NSString stringWithFormat:@"%@:%@", self.username, self.password ?: @""];
        NSData *credData = [creds dataUsingEncoding:NSUTF8StringEncoding];
        NSString *encoded = [credData base64EncodedStringWithOptions:0];
        NSString *h = [NSString stringWithFormat:@"Basic %@", encoded];
        [req setValue:h forHTTPHeaderField:@"Authorization"];
    }

    if (body) {
        NSError *jsonErr = nil;
        NSData *postData = [NSJSONSerialization dataWithJSONObject:body
                                                           options:0
                                                             error:&jsonErr];
        if (!postData) {
            if (error) {
                *error = [self makeError:MongrelDBErrorQuery
                                 message:[NSString stringWithFormat:@"cannot encode request: %@",
                                           jsonErr.localizedDescription]];
            }
            return nil;
        }
        req.HTTPBody = postData;
        [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [req setValue:[NSString stringWithFormat:@"%lu", (unsigned long)postData.length]
       forHTTPHeaderField:@"Content-Length"];
    }

    __block NSData *respData = nil;
    __block NSHTTPURLResponse *httpResp = nil;
    __block NSError *netErr = nil;

    /* NSURLSession's completionHandler API is asynchronous; wrap it in a
     * semaphore so the public methods are synchronous (simple to reason about
     * and easy to test). */
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task =
        [self.session dataTaskWithRequest:req
                        completionHandler:^(NSData *data, NSURLResponse *response, NSError *err) {
        respData = data;
        httpResp = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        netErr = err;
        dispatch_semaphore_signal(sem);
    }];
    [task resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW,
        (int64_t)(self.timeout + 30) * NSEC_PER_SEC));

    if (netErr) {
        if (error) {
            *error = [self makeError:MongrelDBErrorNetwork
                             message:[NSString stringWithFormat:@"network error: %@",
                                       netErr.localizedDescription]];
        }
        return nil;
    }

    NSInteger status = httpResp.statusCode;
    /* Cap the response body at 256 MB so a runaway query cannot exhaust memory. */
    if (respData.length > (NSUInteger)MongrelDBMaxResponseBytes) {
        if (error) {
            *error = [self makeError:MongrelDBErrorQuery
                             message:[NSString stringWithFormat:@"response body exceeds %lld bytes",
                                       (long long)MongrelDBMaxResponseBytes]];
        }
        return nil;
    }

    if (status < 200 || status >= 300) {
        /* Decode the daemon's error envelope if present. */
        NSString *message = nil;
        if (respData.length > 0) {
            id parsed = [NSJSONSerialization JSONObjectWithData:respData options:0 error:nil];
            if ([parsed isKindOfClass:[NSDictionary class]]) {
                id errObj = [(NSDictionary *)parsed objectForKey:@"error"];
                if ([errObj isKindOfClass:[NSDictionary class]]) {
                    message = [(NSDictionary *)errObj objectForKey:@"message"];
                } else if ([errObj isKindOfClass:[NSString class]]) {
                    message = (NSString *)errObj;
                }
            }
        }
        if (message.length == 0) {
            message = [NSString stringWithFormat:@"server error (%ld)", (long)status];
        }
        if (error) {
            MongrelDBErrorCode code = MongrelDBErrorCodeForHTTP(status);
            *error = [self makeError:code message:message];
        }
        return nil;
    }

    if (respData.length == 0) {
        return nil;
    }
    NSError *decErr = nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:respData options:0 error:&decErr];
    if (decErr) {
        /* Non-JSON 2xx body (e.g. plain "ok" from /health): treat as success
         * with no body. */
        return nil;
    }
    return parsed;
}

/* ── Health & tables ───────────────────────────────────────────────────── */

- (BOOL)health:(NSError *_Nullable *_Nullable)error {
    id r = [self requestMethod:@"GET" path:@"health" body:nil error:error];
    return (r != nil) || (error && *error == nil);
}

- (nullable NSArray<NSString *> *)tableNames:(NSError *_Nullable *_Nullable)error {
    id r = [self requestMethod:@"GET" path:@"tables" body:nil error:error];
    if ([r isKindOfClass:[NSArray class]]) {
        return (NSArray<NSString *> *)r;
    }
    return @[];
}

- (int64_t)createTableWithName:(NSString *)name
                       columns:(NSArray<MongrelDBColumn *> *)columns
                         error:(NSError *_Nullable *_Nullable)error {
    NSMutableArray<NSDictionary *> *cols = [NSMutableArray arrayWithCapacity:columns.count];
    for (MongrelDBColumn *c in columns) {
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"id"] = @(c.columnId);
        if (c.name) { d[@"name"] = c.name; }
        if (c.type) { d[@"ty"] = c.type; }
        d[@"primary_key"] = @(c.primaryKey);
        d[@"nullable"] = @(c.nullable);
        if (c.enumVariants.count > 0) { d[@"enum_variants"] = c.enumVariants; }
        if (c.defaultValue) { d[@"default_value"] = c.defaultValue; }
        [cols addObject:d];
    }
    NSDictionary *body = @{@"name": name ?: @"", @"columns": cols};
    id r = [self requestMethod:@"POST" path:@"kit/create_table" body:body error:error];
    if ([r isKindOfClass:[NSDictionary class]]) {
        NSNumber *tid = [(NSDictionary *)r objectForKey:@"table_id"];
        if ([tid isKindOfClass:[NSNumber class]]) {
            return tid.longLongValue;
        }
    }
    return 0;
}

- (BOOL)dropTableWithName:(NSString *)name error:(NSError *_Nullable *_Nullable)error {
    NSString *seg = [MongrelDBClient encodeSegment:name];
    [self requestMethod:@"DELETE" path:[NSString stringWithFormat:@"tables/%@", seg] body:nil error:error];
    return (error && *error == nil);
}

- (int64_t)countOfTable:(NSString *)table error:(NSError *_Nullable *_Nullable)error {
    NSString *seg = [MongrelDBClient encodeSegment:table];
    id r = [self requestMethod:@"GET" path:[NSString stringWithFormat:@"tables/%@/count", seg] body:nil error:error];
    if ([r isKindOfClass:[NSDictionary class]]) {
        NSNumber *n = [(NSDictionary *)r objectForKey:@"count"];
        if ([n isKindOfClass:[NSNumber class]]) {
            return n.longLongValue;
        }
    }
    return 0;
}

/* ── Cell serialization helpers ────────────────────────────────────────── */

/* Build the flat cells array the server expects: [col_id, value, ...]. */
- (NSArray *)flattenCells:(NSArray<MongrelDBInputCell *> *)cells {
    NSMutableArray *flat = [NSMutableArray arrayWithCapacity:cells.count * 2];
    for (MongrelDBInputCell *c in cells) {
        [flat addObject:@(c.columnId)];
        [flat addObject:c.value ?: NSNull.null];
    }
    return flat;
}

/* ── CRUD (single-op transactions) ─────────────────────────────────────── */

- (BOOL)putIntoTable:(NSString *)table
               cells:(NSArray<MongrelDBInputCell *> *)cells
      idempotencyKey:(nullable NSString *)idempotencyKey
               error:(NSError *_Nullable *_Nullable)error {
    return [self transactionWithOps:@[
        @{@"put": @{@"table": table ?: @"",
                    @"cells": [self flattenCells:cells],
                    @"returning": @NO}},
    ] idempotencyKey:idempotencyKey error:error] != nil || (error && *error == nil);
}

- (BOOL)upsertIntoTable:(NSString *)table
                  cells:(NSArray<MongrelDBInputCell *> *)cells
           updateCells:(nullable NSArray<MongrelDBInputCell *> *)updateCells
         idempotencyKey:(nullable NSString *)idempotencyKey
                  error:(NSError *_Nullable *_Nullable)error {
    NSMutableDictionary *op = [NSMutableDictionary dictionary];
    op[@"table"] = table ?: @"";
    op[@"cells"] = [self flattenCells:cells];
    if (updateCells.count > 0) {
        op[@"update_cells"] = [self flattenCells:updateCells];
    }
    op[@"returning"] = @NO;
    return [self transactionWithOps:@[@{@"upsert": op}]
                     idempotencyKey:idempotencyKey error:error] != nil || (error && *error == nil);
}

- (BOOL)deleteFromTable:(NSString *)table
                 rowId:(int64_t)rowId
                 error:(NSError *_Nullable *_Nullable)error {
    return [self transactionWithOps:@[
        @{@"delete": @{@"table": table ?: @"", @"row_id": @(rowId)}},
    ] idempotencyKey:nil error:error] != nil || (error && *error == nil);
}

- (BOOL)deleteFromTable:(NSString *)table
        primaryKeyValue:(MongrelDBValue)pk
                  error:(NSError *_Nullable *_Nullable)error {
    return [self transactionWithOps:@[
        @{@"delete_by_pk": @{@"table": table ?: @"", @"pk": pk ?: NSNull.null}},
    ] idempotencyKey:nil error:error] != nil || (error && *error == nil);
}

/* ── Batch transactions ────────────────────────────────────────────────── */

- (nullable NSArray<NSDictionary *> *)transactionWithOps:(NSArray<NSDictionary *> *)ops
                                          idempotencyKey:(nullable NSString *)idempotencyKey
                                                   error:(NSError *_Nullable *_Nullable)error {
    NSMutableDictionary *body = [NSMutableDictionary dictionary];
    body[@"ops"] = ops ?: @[];
    if (idempotencyKey.length > 0) {
        body[@"idempotency_key"] = idempotencyKey;
    }
    id r = [self requestMethod:@"POST" path:@"kit/txn" body:body error:error];
    if ([r isKindOfClass:[NSDictionary class]]) {
        id results = [(NSDictionary *)r objectForKey:@"results"];
        if ([results isKindOfClass:[NSArray class]]) {
            return (NSArray<NSDictionary *> *)results;
        }
    }
    return @[];
}

/* ── Query ─────────────────────────────────────────────────────────────── */

/* Serialize one condition into its wire shape. */
- (NSDictionary *)serializeCondition:(MongrelDBCondition *)cond {
    switch (cond.kind) {
        case MongrelDBConditionPK:
            return @{@"pk": @{@"value": cond.value ?: NSNull.null}};
        case MongrelDBConditionBitmapEq:
            return @{@"bitmap_eq": @{@"column_id": @(cond.columnId),
                                     @"value": cond.value ?: NSNull.null}};
        case MongrelDBConditionRange: {
            NSMutableDictionary *d = [NSMutableDictionary dictionary];
            d[@"column_id"] = @(cond.columnId);
            if (cond.loSet) { d[@"lo"] = @(cond.lo); }
            if (cond.hiSet) { d[@"hi"] = @(cond.hi); }
            return @{@"range": d};
        }
        case MongrelDBConditionFmContains:
            return @{@"fm_contains": @{@"column_id": @(cond.columnId),
                                       @"pattern": cond.value ?: @""}};
        case MongrelDBConditionIsNull:
            return @{@"is_null": @{@"column_id": @(cond.columnId)}};
        case MongrelDBConditionIsNotNull:
            return @{@"is_not_null": @{@"column_id": @(cond.columnId)}};
    }
    return @{@"pk": @{@"value": NSNull.null}};
}

- (nullable NSArray<NSDictionary *> *)queryTable:(NSString *)table
                                      conditions:(nullable NSArray<MongrelDBCondition *> *)conditions
                                      projection:(nullable NSArray<NSNumber *> *)projection
                                           limit:(int64_t)limit
                                       truncated:(nullable BOOL *)truncated
                                          error:(NSError *_Nullable *_Nullable)error {
    NSMutableDictionary *body = [NSMutableDictionary dictionary];
    body[@"table"] = table ?: @"";
    if (conditions.count > 0) {
        NSMutableArray *arr = [NSMutableArray arrayWithCapacity:conditions.count];
        for (MongrelDBCondition *c in conditions) {
            [arr addObject:[self serializeCondition:c]];
        }
        body[@"conditions"] = arr;
    }
    if (projection.count > 0) {
        body[@"projection"] = projection;
    }
    if (limit > 0) {
        body[@"limit"] = @(limit);
    }

    id r = [self requestMethod:@"POST" path:@"kit/query" body:body error:error];
    if (![r isKindOfClass:[NSDictionary class]]) {
        return @[];
    }
    NSDictionary *resp = (NSDictionary *)r;
    if (truncated) {
        NSNumber *t = [resp objectForKey:@"truncated"];
        *truncated = [t boolValue];
    }
    id rows = [resp objectForKey:@"rows"];
    if (![rows isKindOfClass:[NSArray class]]) {
        return @[];
    }
    /* The daemon returns each row as
     *   {"row_id":"0","cells":[col_id, value, col_id, value, ...]}
     * with a flat cells array. Decode each row into a column-id-keyed
     * dictionary (keys are NSNumber column ids) so callers can do
     * [row objectForKey:@(columnId)]. */
    NSMutableArray *decoded = [NSMutableArray arrayWithCapacity:[(NSArray *)rows count]];
    for (id raw in (NSArray *)rows) {
        NSDictionary *decodedRow = [self decodeQueryRow:raw];
        [decoded addObject:decodedRow];
    }
    return decoded;
}

/* Decode one /kit/query row: expand the flat `cells` array into a
 * column-id-keyed dictionary. Falls back to the raw object when the shape
 * is unexpected so callers still get something usable. */
- (NSDictionary *)decodeQueryRow:(id)raw {
    if (![raw isKindOfClass:[NSDictionary class]]) {
        return raw ?: @{};
    }
    NSDictionary *row = (NSDictionary *)raw;
    id cells = [row objectForKey:@"cells"];
    if (![cells isKindOfClass:[NSArray class]]) {
        return row;
    }
    NSArray *flat = (NSArray *)cells;
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    /* Preserve row_id so callers that need the engine-assigned id can read it. */
    id rowId = [row objectForKey:@"row_id"];
    if (rowId) {
        out[@"row_id"] = rowId;
    }
    /* Flat array: even indices are column ids (NSNumber), odd indices values. */
    NSUInteger n = flat.count;
    NSUInteger i = 0;
    while (i + 1 < n) {
        id colId = flat[i];
        id val = flat[i + 1];
        if (colId) {
            out[colId] = val ?: NSNull.null;
        }
        i += 2;
    }
    return out;
}

/* ── SQL & schema ──────────────────────────────────────────────────────── */

- (nullable id)sql:(NSString *)sql error:(NSError *_Nullable *_Nullable)error {
    return [self requestMethod:@"POST" path:@"sql"
                         body:@{@"sql": sql ?: @"", @"format": @"json"} error:error];
}

- (nullable NSDictionary *)schema:(NSError *_Nullable *_Nullable)error {
    id r = [self requestMethod:@"GET" path:@"kit/schema" body:nil error:error];
    return [r isKindOfClass:[NSDictionary class]] ? (NSDictionary *)r : @{};
}

- (nullable NSDictionary *)schemaForTable:(NSString *)table
                                    error:(NSError *_Nullable *_Nullable)error {
    NSString *seg = [MongrelDBClient encodeSegment:table];
    id r = [self requestMethod:@"GET" path:[NSString stringWithFormat:@"kit/schema/%@", seg] body:nil error:error];
    return [r isKindOfClass:[NSDictionary class]] ? (NSDictionary *)r : @{};
}

@end
