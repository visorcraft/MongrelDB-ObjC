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

@interface MongrelDBClient ()
/* Internal raw GET /history/retention response used by the scalar getters. */
- (nullable NSDictionary<NSString *, NSNumber *> *)historyRetention:(NSError *_Nullable *_Nullable)error;
@end

/* ── Constants ─────────────────────────────────────────────────────────── */

NSString *const MongrelDBDefaultURL = @"http://127.0.0.1:8453";
const int64_t MongrelDBMaxResponseBytes = 268435456LL; /* 256 MB */

/* ── MongrelDBInputCell ────────────────────────────────────────────────── */

@implementation MongrelDBInputCell

+ (instancetype)cellWithColumnId:(uint16_t)columnId value:(nullable MongrelDBValue)value {
    return [[self alloc] initWithColumnId:columnId value:value];
}

- (instancetype)initWithColumnId:(uint16_t)columnId value:(nullable MongrelDBValue)value {
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

+ (instancetype)columnWithId:(uint16_t)columnId
                        name:(nullable NSString *)name
                        type:(nullable NSString *)type
                 primaryKey:(BOOL)primaryKey
                  isNullable:(BOOL)isNullable {
    MongrelDBColumn *c = [[self alloc] init];
    if (c) {
        c.columnId = columnId;
        c.name = [name copy];
        c.type = [type copy];
        c.primaryKey = primaryKey;
        c.isNullable = isNullable;
    }
    return c;
}

@end

/* ── MongrelDBCondition ────────────────────────────────────────────────── */

@implementation MongrelDBCondition
@end

/* ── MongrelDBClient ───────────────────────────────────────────────────── */

@interface MongrelDBClient () <NSURLSessionTaskDelegate>
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

/* Convenience init override. Required because initWithURL:token:username:password:error:
 * is the designated initializer: NSObject's own -init is designated in the
 * superclass, so the subclass must override it and chain to its own designated
 * initializer. Subclasses of MongrelDBClient that override init must similarly
 * chain to initWithURL:token:username:password:error:. */
- (instancetype)init {
    return [self initWithURL:nil token:nil username:nil password:nil error:nil];
}

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
    NSCharacterSet *crlfSet = [NSCharacterSet characterSetWithCharactersInString:@"\r\n"];
    for (NSString *c in creds) {
        if ([c rangeOfCharacterFromSet:crlfSet].location != NSNotFound) {
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
    _lastEpoch = 0;
    _errorLock = [[NSLock alloc] init];
    _lastErrorStr = @"";

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    /* Never follow redirects: an Authorization header could follow a redirect
     * to an attacker-controlled host. The delegate method below enforces this. */
    cfg.HTTPShouldSetCookies = NO;
    cfg.timeoutIntervalForRequest = 30.0;
    cfg.timeoutIntervalForResource = 60.0;
    cfg.URLCache = nil;
    _session = [NSURLSession sessionWithConfiguration:cfg
                                             delegate:self
                                        delegateQueue:[NSOperationQueue new]];

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

/* NSURLSessionTaskDelegate: cancel all HTTP redirects so the Authorization
 * header cannot leak to an attacker-controlled host. */
- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
willPerformHTTPRedirection:(NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest *_Nullable))completionHandler {
    (void)session; (void)task; (void)response; (void)request;
    if (completionHandler) {
        completionHandler(nil);
    }
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

/* Core synchronous request helper. Returns YES on a 2xx response. On success,
 * *outResponse is set to the decoded JSON body (or nil for an empty or plain-
 * text body such as /health). On failure, *error is set. */
- (BOOL)performRequestMethod:(NSString *)method
                        path:(NSString *)path
                       body:(nullable NSDictionary *)body
                   response:(id *_Nullable)outResponse
                      error:(NSError *_Nullable *_Nullable)error {
    if (outResponse) {
        *outResponse = nil;
    }

    NSString *urlStr = [NSString stringWithFormat:@"%@/%@", self.baseURL, path];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) {
        if (error) {
            *error = [self makeError:MongrelDBErrorInvalidArg message:@"invalid URL"];
        }
        return NO;
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
            return NO;
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
        return NO;
    }

    NSInteger status = httpResp.statusCode;
    /* Cap the response body at 256 MB so a runaway query cannot exhaust memory. */
    if (respData.length > (NSUInteger)MongrelDBMaxResponseBytes) {
        if (error) {
            *error = [self makeError:MongrelDBErrorQuery
                             message:[NSString stringWithFormat:@"response body exceeds %lld bytes",
                                       (long long)MongrelDBMaxResponseBytes]];
        }
        return NO;
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
            message = [[NSString alloc] initWithData:respData encoding:NSUTF8StringEncoding];
        }
        if (message.length == 0) {
            message = [NSString stringWithFormat:@"server error (%ld)", (long)status];
        }
        if (error) {
            MongrelDBErrorCode code = MongrelDBErrorCodeForHTTP(status);
            if ([message hasPrefix:@"not found:"]) {
                code = MongrelDBErrorNotFound;
            }
            *error = [self makeError:code message:message];
        }
        return NO;
    }

    if (respData.length == 0) {
        return YES;
    }
    NSError *decErr = nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:respData options:0 error:&decErr];
    if (decErr) {
        /* /health returns a plain-text 2xx body; treat that as success. */
        if ([path isEqualToString:@"health"]) {
            return YES;
        }
        if (error) {
            *error = [self makeError:MongrelDBErrorJSON
                             message:[NSString stringWithFormat:@"cannot decode response: %@",
                                       decErr.localizedDescription]];
        }
        return NO;
    }
    if (outResponse) {
        *outResponse = parsed;
    }
    return YES;
}

/* Synchronous request helper. Returns the decoded JSON body (or nil on failure
 * or for empty bodies). Sets *error on failure. */
- (nullable id)requestMethod:(NSString *)method
                        path:(NSString *)path
                       body:(nullable NSDictionary *)body
                      error:(NSError *_Nullable *_Nullable)error {
    id response = nil;
    BOOL ok = [self performRequestMethod:method path:path body:body response:&response error:error];
    return ok ? response : nil;
}

/* ── Health & tables ───────────────────────────────────────────────────── */

- (BOOL)health:(NSError *_Nullable *_Nullable)error {
    return [self performRequestMethod:@"GET" path:@"health" body:nil response:nil error:error];
}

- (nullable NSArray<NSString *> *)tableNames:(NSError *_Nullable *_Nullable)error {
    id r = [self requestMethod:@"GET" path:@"tables" body:nil error:error];
    if ([r isKindOfClass:[NSArray class]]) {
        return (NSArray<NSString *> *)r;
    }
    return @[];
}

- (nullable NSDictionary<NSString *, NSNumber *> *)setHistoryRetentionEpochs:(uint64_t)epochs error:(NSError *_Nullable *_Nullable)error {
    id r = [self requestMethod:@"PUT" path:@"history/retention" body:@{@"history_retention_epochs": @(epochs)} error:error];
    return [r isKindOfClass:[NSDictionary class]] ? r : nil;
}

- (nullable NSDictionary<NSString *, NSNumber *> *)historyRetention:(NSError *_Nullable *_Nullable)error {
    id r = [self requestMethod:@"GET" path:@"history/retention" body:nil error:error];
    return [r isKindOfClass:[NSDictionary class]] ? r : nil;
}

- (uint64_t)historyRetentionEpochs:(NSError *_Nullable *_Nullable)error {
    return [self historyRetention:error][@"history_retention_epochs"].unsignedLongLongValue;
}

- (uint64_t)earliestRetainedEpoch:(NSError *_Nullable *_Nullable)error {
    return [self historyRetention:error][@"earliest_retained_epoch"].unsignedLongLongValue;
}

- (int64_t)createTableWithName:(NSString *)name
                       columns:(NSArray<MongrelDBColumn *> *)columns
                         error:(NSError *_Nullable *_Nullable)error {
    return [self createTableWithName:name columns:columns constraints:nil error:error];
}

- (int64_t)createTableWithName:(NSString *)name
                       columns:(NSArray<MongrelDBColumn *> *)columns
                   constraints:(nullable NSDictionary<NSString *, id> *)constraints
                         error:(NSError *_Nullable *_Nullable)error {
    NSMutableArray<NSDictionary *> *cols = [NSMutableArray arrayWithCapacity:columns.count];
    for (MongrelDBColumn *c in columns) {
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"id"] = @(c.columnId);
        if (c.name) { d[@"name"] = c.name; }
        if (c.type) { d[@"ty"] = c.type; }
        d[@"primary_key"] = @(c.primaryKey);
        d[@"nullable"] = @(c.isNullable);
        if (c.enumVariants.count > 0) { d[@"enum_variants"] = c.enumVariants; }
        if (c.defaultExpression) { d[@"default_expr"] = c.defaultExpression; }
        else if (c.defaultValueJSON) { d[@"default_value"] = c.defaultValueJSON; }
        else if (c.defaultValue) { d[@"default_value"] = c.defaultValue; }
        [cols addObject:d];
    }
    NSMutableDictionary *body = [@{@"name": name ?: @"", @"columns": cols} mutableCopy];
    if (constraints) { body[@"constraints"] = constraints; }
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
    return [self performRequestMethod:@"DELETE"
                                 path:[NSString stringWithFormat:@"tables/%@", seg]
                                 body:nil
                             response:nil
                                error:error];
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
    ] idempotencyKey:idempotencyKey error:error] != nil;
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
                     idempotencyKey:idempotencyKey error:error] != nil;
}

- (BOOL)deleteFromTable:(NSString *)table
                 rowId:(uint64_t)rowId
                 error:(NSError *_Nullable *_Nullable)error {
    return [self transactionWithOps:@[
        @{@"delete": @{@"table": table ?: @"", @"row_id": @(rowId)}},
    ] idempotencyKey:nil error:error] != nil;
}

- (BOOL)deleteFromTable:(NSString *)table
        primaryKeyValue:(MongrelDBValue)pk
                  error:(NSError *_Nullable *_Nullable)error {
    return [self transactionWithOps:@[
        @{@"delete_by_pk": @{@"table": table ?: @"", @"pk": pk ?: NSNull.null}},
    ] idempotencyKey:nil error:error] != nil;
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
    if (!r) {
        return nil;
    }
    if ([r isKindOfClass:[NSDictionary class]]) {
        NSDictionary *resp = (NSDictionary *)r;
        id results = [resp objectForKey:@"results"];
        if ([results isKindOfClass:[NSArray class]]) {
            /* Capture the commit epoch whenever the server reports one. */
            id status = [resp objectForKey:@"status"];
            id epoch = [resp objectForKey:@"epoch"];
            if ([status isKindOfClass:[NSString class]] &&
                [status isEqualToString:@"committed"] &&
                [epoch isKindOfClass:[NSNumber class]]) {
                unsigned long long epochValue = [(NSNumber *)epoch unsignedLongLongValue];
                self.lastEpoch = (uint64_t)epochValue;
            }
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
        case MongrelDBConditionRangeF64: {
            NSMutableDictionary *d = [NSMutableDictionary dictionary];
            d[@"column_id"] = @(cond.columnId);
            if (cond.loSet) { d[@"lo"] = @(cond.loF64); }
            if (cond.hiSet) { d[@"hi"] = @(cond.hiF64); }
            d[@"lo_inclusive"] = @(cond.loInclusive);
            d[@"hi_inclusive"] = @(cond.hiInclusive);
            return @{@"range_f64": d};
        }
        case MongrelDBConditionFmContains: {
            NSString *pattern = @"";
            if ([cond.value isKindOfClass:[NSString class]]) {
                pattern = (NSString *)cond.value;
            } else if (cond.value != nil && cond.value != NSNull.null) {
                pattern = [NSString stringWithFormat:@"%@", cond.value];
            }
            return @{@"fm_contains": @{@"column_id": @(cond.columnId),
                                       @"pattern": pattern}};
        }
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
        return @{};
    }
    NSDictionary *row = (NSDictionary *)raw;
    id cells = [row objectForKey:@"cells"];
    if (![cells isKindOfClass:[NSArray class]]) {
        return @{};
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
