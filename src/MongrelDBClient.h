/*
 * MongrelDBClient.h - Objective-C (Apple Foundation) HTTP client for MongrelDB.
 *
 * MongrelDB-ObjC is an NSURLSession-based client that talks to a running
 * mongreldb-server daemon's JSON API. It mirrors the surface of the C, PHP,
 * Go, and other official clients: typed CRUD over the Kit transaction endpoint,
 * a query builder that pushes conditions down to the engine's native indexes,
 * batch transactions with idempotency keys, full SQL access, and schema
 * introspection.
 *
 * Memory model:
 *   - MongrelDBClient is a normal Objective-C object under ARC. Retain/release
 *     as usual; result arrays returned from query are regular NSArray instances
 *     the caller owns.
 *   - NSError out-parameters are autoreleased.
 *
 * Thread safety:
 *   - MongrelDBClient is thread-safe. Internally it serializes requests through
 *     a single NSURLSession on a delegate queue, and guards its mutable error
 *     state with a lock. For high concurrency prefer one client per logical
 *     user rather than sharing one across many threads.
 *
 * Authentication:
 *   - Bearer token (--auth-token mode): connectWithURL:token:error:.
 *   - HTTP Basic (--auth-users mode): connectWithURL:username:password:error:.
 *
 * Licensing: MIT OR Apache-2.0.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 */

#import <Foundation/Foundation.h>

#import "MongrelDBError.h"

NS_ASSUME_NONNULL_BEGIN

/* Default daemon URL when none is supplied. */
FOUNDATION_EXPORT NSString *const MongrelDBDefaultURL;

/* Cap on a response body size (256 MB). Bodies larger than this are aborted
 * with MongrelDBErrorQuery. */
FOUNDATION_EXPORT const int64_t MongrelDBMaxResponseBytes;

/* A single typed value used in input cells. Strings are NSString; integers
 * come back as NSNumber with objCType "q" (long long); doubles as NSNumber
 * with objCType "d"; booleans as NSNumber with objCType "B" / @YES/@NO;
 * NSNull represents NULL. This mirrors how NSJSONSerialization represents
 * JSON values. */
typedef id MongrelDBValue;

/* A single input cell: column id paired with a value, used by put/upsert. */
@interface MongrelDBInputCell : NSObject
@property (nonatomic, assign) uint16_t columnId;
@property (nonatomic, strong, nullable) MongrelDBValue value;
+ (instancetype)cellWithColumnId:(uint16_t)columnId value:(nullable MongrelDBValue)value;
- (instancetype)initWithColumnId:(uint16_t)columnId value:(nullable MongrelDBValue)value;
@end

/* Column definition passed to createTable. Column ids are stable on-wire
 * identifiers used everywhere else (cells, conditions, projection). */
@interface MongrelDBColumn : NSObject
@property (nonatomic, assign) uint16_t columnId;
@property (nonatomic, copy, nullable) NSString *name;
@property (nonatomic, copy, nullable) NSString *type;     /* "int64","varchar","float64","bool",... */
@property (nonatomic, assign) BOOL primaryKey;
@property (nonatomic, assign) BOOL isNullable;
/* Optional: fixed set of allowed values for an enum column. nil = absent.
 * Wire emit: "enum_variants": ["a","b"]. */
@property (nonatomic, copy, nullable) NSArray<NSString *> *enumVariants;
/* Optional: default string value for the column. nil = absent.
 * Wire emit: "default_value": "<string>". */
@property (nonatomic, copy, nullable) NSString *defaultValue;
/* Optional static JSON scalar. Has precedence over defaultValue. */
@property (nonatomic, copy, nullable) MongrelDBValue defaultValueJSON;
/* Optional dynamic default: "now" or "uuid". Has the highest precedence. */
@property (nonatomic, copy, nullable) NSString *defaultExpression;
+ (instancetype)columnWithId:(uint16_t)columnId
                        name:(nullable NSString *)name
                        type:(nullable NSString *)type
                 primaryKey:(BOOL)primaryKey
                  isNullable:(BOOL)isNullable;
@end

/* A query condition. Set kind and the relevant fields; see the convenience
 * constructors for each condition type. */
typedef NS_ENUM(NSInteger, MongrelDBConditionKind) {
    MongrelDBConditionPK           = 0,
    MongrelDBConditionBitmapEq     = 1,
    MongrelDBConditionRange        = 2,
    MongrelDBConditionFmContains   = 3,
    MongrelDBConditionIsNull       = 4,
    MongrelDBConditionIsNotNull    = 5,
    MongrelDBConditionRangeF64     = 6,
};

@interface MongrelDBCondition : NSObject
@property (nonatomic, assign) MongrelDBConditionKind kind;
@property (nonatomic, assign) uint16_t columnId;
/* Range endpoints. Use lo/hi for integer ranges (MongrelDBConditionRange);
 * loF64/hiF64 for floating-point ranges (MongrelDBConditionRangeF64). */
@property (nonatomic, assign) int64_t lo;
@property (nonatomic, assign) int64_t hi;
@property (nonatomic, assign) double loF64;
@property (nonatomic, assign) double hiF64;
@property (nonatomic, assign) BOOL loInclusive;
@property (nonatomic, assign) BOOL hiInclusive;
@property (nonatomic, assign) BOOL loSet;
@property (nonatomic, assign) BOOL hiSet;
/* PK match / bitmap_eq value / fm_contains pattern (must be NSString). */
@property (nonatomic, strong, nullable) MongrelDBValue value;
@end

/* The main client. Construct with a connect* class method and release normally. */
@interface MongrelDBClient : NSObject

/* The daemon base URL this client targets (no trailing slash). */
@property (nonatomic, readonly, copy) NSString *baseURL;

/* Epoch of the most recent successful /kit/txn commit captured from the
 * daemon response. Updated only when the response status is "committed" and
 * an epoch is present; 0 if no commit has been observed yet. */
@property (nonatomic, assign) uint64_t lastEpoch;

/* Open mode: no credentials. Pass nil or empty url to use MongrelDBDefaultURL. */
+ (nullable instancetype)connectWithURL:(nullable NSString *)url
                                  error:(NSError *_Nullable *_Nullable)error;
/* Bearer token mode (--auth-token). */
+ (nullable instancetype)connectWithURL:(nullable NSString *)url
                                  token:(nullable NSString *)token
                                  error:(NSError *_Nullable *_Nullable)error;
/* HTTP Basic mode (--auth-users). */
+ (nullable instancetype)connectWithURL:(nullable NSString *)url
                               username:(nullable NSString *)username
                               password:(nullable NSString *)password
                                  error:(NSError *_Nullable *_Nullable)error;

/* Designated initializer. Prefer the connectWithURL: convenience constructors
 * unless you need to subclass MongrelDBClient. Any subclass that overrides
 * init must chain to this via [super initWithURL:token:username:password:error:].
 * Pass nil/empty url to use MongrelDBDefaultURL; pass nil credentials for open
 * mode, a token for bearer mode, or username/password for HTTP Basic. */
- (nullable instancetype)initWithURL:(nullable NSString *)url
                               token:(nullable NSString *)token
                            username:(nullable NSString *)username
                            password:(nullable NSString *)password
                               error:(NSError *_Nullable *_Nullable)error
NS_DESIGNATED_INITIALIZER;

/* Convenience initializer inherited from NSObject. Chains to the designated
 * initializer with all-default credentials so subclasses can override init
 * without bypassing MongrelDBClient's setup. Prefer the connectWithURL:
 * constructors or initWithURL:token:username:password:error: directly. */
- (instancetype)init;

/* Per-request timeout in seconds (default 30). */
- (void)setTimeout:(NSTimeInterval)seconds;

/* Message for the most recent failure on this client (empty string if none).
 * Primarily for logging; prefer the NSError out-parameters from each method. */
- (NSString *)lastError;

#pragma mark Health & tables

/* GET /health. Returns YES on success. */
- (BOOL)health:(NSError *_Nullable *_Nullable)error;

/* GET /tables. Returns the list of table names. */
- (nullable NSArray<NSString *> *)tableNames:(NSError *_Nullable *_Nullable)error;

- (nullable NSDictionary<NSString *, NSNumber *> *)setHistoryRetentionEpochs:(uint64_t)epochs error:(NSError *_Nullable *_Nullable)error;
- (uint64_t)historyRetentionEpochs:(NSError *_Nullable *_Nullable)error;
- (uint64_t)earliestRetainedEpoch:(NSError *_Nullable *_Nullable)error;

/* POST /kit/create_table. Returns the assigned table id (0 if none reported). */
- (int64_t)createTableWithName:(NSString *)name
                       columns:(NSArray<MongrelDBColumn *> *)columns
                         error:(NSError *_Nullable *_Nullable)error;

/* Same request with a top-level engine constraints object. */
- (int64_t)createTableWithName:(NSString *)name
                       columns:(NSArray<MongrelDBColumn *> *)columns
                   constraints:(nullable NSDictionary<NSString *, id> *)constraints
                         error:(NSError *_Nullable *_Nullable)error;

/* DELETE /tables/{name}. */
- (BOOL)dropTableWithName:(NSString *)name
                    error:(NSError *_Nullable *_Nullable)error;

/* GET /tables/{name}/count. */
- (int64_t)countOfTable:(NSString *)table
                  error:(NSError *_Nullable *_Nullable)error;

#pragma mark CRUD (single-op transactions)

/* Insert a row. idempotencyKey (or nil) makes the commit safe to retry. */
- (BOOL)putIntoTable:(NSString *)table
               cells:(NSArray<MongrelDBInputCell *> *)cells
      idempotencyKey:(nullable NSString *)idempotencyKey
               error:(NSError *_Nullable *_Nullable)error;

/* Insert or update on PK conflict. updateCells (or nil) supplies the values
 * written on conflict (nil = do nothing on conflict). */
- (BOOL)upsertIntoTable:(NSString *)table
                  cells:(NSArray<MongrelDBInputCell *> *)cells
           updateCells:(nullable NSArray<MongrelDBInputCell *> *)updateCells
         idempotencyKey:(nullable NSString *)idempotencyKey
                  error:(NSError *_Nullable *_Nullable)error;

/* Delete by internal row id. */
- (BOOL)deleteFromTable:(NSString *)table
                 rowId:(uint64_t)rowId
                 error:(NSError *_Nullable *_Nullable)error;

/* Delete by primary-key value. */
- (BOOL)deleteFromTable:(NSString *)table
        primaryKeyValue:(MongrelDBValue)pk
                  error:(NSError *_Nullable *_Nullable)error;

#pragma mark Batch transactions

/* Stage an ops array and commit atomically. Each op is one of:
 *   @{@"put":@{@"table":t, @"cells":[...], @"returning":@NO}}
 *   @{@"upsert":@{@"table":t, @"cells":[...], @"update_cells":[...], @"returning":@NO}}
 *   @{@"delete":@{@"table":t, @"row_id":@(id)}}
 *   @{@"delete_by_pk":@{@"table":t, @"pk":<value>}}
 * idempotencyKey (or nil) makes the commit safe to retry. Returns the raw
 * per-op results array (empty if none). */
- (nullable NSArray<NSDictionary *> *)transactionWithOps:(NSArray<NSDictionary *> *)ops
                                          idempotencyKey:(nullable NSString *)idempotencyKey
                                                   error:(NSError *_Nullable *_Nullable)error;

#pragma mark Query

/* POST /kit/query. conditions (or nil) are AND-ed; projection (or nil)
 * restricts returned column ids; limit (or 0) caps the count. truncated is set
 * to YES when the result hit the limit. Returns the rows array; each row is an
 * NSDictionary mapping column-id (NSNumber) -> value. Every row also contains
 * an @"row_id" entry with the engine-assigned row id. */
- (nullable NSArray<NSDictionary *> *)queryTable:(NSString *)table
                                      conditions:(nullable NSArray<MongrelDBCondition *> *)conditions
                                      projection:(nullable NSArray<NSNumber *> *)projection
                                           limit:(int64_t)limit
                                       truncated:(nullable BOOL *)truncated
                                          error:(NSError *_Nullable *_Nullable)error;

#pragma mark SQL & schema

/* POST /sql {"sql":...,"format":"json"}. Returns the decoded JSON body (an
 * array of rows for SELECT, or an empty array for DDL/DML). */
- (nullable id)sql:(NSString *)sql error:(NSError *_Nullable *_Nullable)error;

/* GET /kit/schema. Returns the full schema catalog. */
- (nullable NSDictionary *)schema:(NSError *_Nullable *_Nullable)error;

/* GET /kit/schema/{table}. Returns the descriptor for a single table. */
- (nullable NSDictionary *)schemaForTable:(NSString *)table
                                    error:(NSError *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END
