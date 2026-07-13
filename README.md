<p align="center">
  <img src="assets/mongrel.png" alt="MongrelDB logo" width="250" />
</p>

<h1 align="center">MongrelDB Objective-C Client</h1>

<p align="center">
  <b>Objective-C (Apple Foundation) HTTP client for MongrelDB - embedded+server database with SQL, vector search, full-text search, and AI-native retrieval.</b>
  <br />
  Built on NSURLSession and NSJSONSerialization. No external runtime dependencies beyond Apple Foundation.
</p>

<p align="center">
  <a href="https://github.com/visorcraft/MongrelDB-ObjC/actions/workflows/ci.yml"><img src="https://github.com/visorcraft/MongrelDB-ObjC/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
  <a href="https://github.com/visorcraft/MongrelDB/releases"><img src="https://img.shields.io/badge/server-v0.50.0-blue.svg" alt="MongrelDB server" /></a>
  <a href="#license"><img src="https://img.shields.io/badge/license-MIT%20OR%20Apache--2.0-blue.svg" alt="License" /></a>
</p>

## Package

| Surface | Package | Install |
|---|---|---|
| Objective-C client | `MongrelDB-ObjC` | build from source with CMake + Apple frameworks |

## Requirements

- **An Objective-C compiler** (clang, Apple LLVM) on macOS
- **Apple Foundation** (NSURLSession, NSJSONSerialization) - ships with macOS/iOS
- **CMake 3.16 or newer** (to build)
- A running [`mongreldb-server`](https://github.com/visorcraft/MongrelDB) daemon

## What It Provides

- **Typed CRUD** over the Kit transaction endpoint: `putIntoTable:cells:`, `upsertIntoTable:cells:updateCells:` (insert-or-update on PK conflict), `deleteFromTable:rowId:` and `deleteFromTable:primaryKeyValue:`, with idempotency keys for safe retries.
- **Query builder** that pushes conditions down to the engine's specialized indexes for sub-millisecond lookups: bitmap equality, learned-range, null checks, and FM-index full-text search. Conditions are AND-ed.
- **Idempotent batch transactions** - all operations staged locally and committed atomically, with the engine enforcing unique, foreign key, and check constraints at commit time. Idempotency keys return the original response on duplicate commits, even after a crash.
- **Full SQL access** through the DataFusion-backed `/sql` endpoint: recursive CTEs, window functions, `CREATE TABLE AS SELECT`, and multi-statement execution.
- **Schema management**: typed table creation, full schema catalog, and per-table descriptors.
- **Typed error codes**: `MongrelDBErrorAuth` (401/403), `MongrelDBErrorNotFound` (404), `MongrelDBErrorConflict` (409), `MongrelDBErrorQuery` (400/5xx), plus `MongrelDBErrorNetwork` and `MongrelDBErrorJSON`. Retrieve the detail from the NSError's `localizedDescription`.
- **ARC-friendly**: result arrays are plain NSArray objects the caller owns; no manual retain/release beyond the client itself.

## Examples

Runnable, commented examples live in the docs:

- [Quickstart](docs/quickstart.md) - install, start the daemon, write and run a complete program.
- [Transactions](docs/transactions.md) - batch commits, idempotency keys, constraint handling.
- [Queries](docs/queries.md) - every native condition type and the index it pushes down to.
- [SQL](docs/sql.md) - recursive CTEs, window functions, advanced SQL.
- [Authentication](docs/auth.md) - bearer token, HTTP Basic, and open modes.
- [Errors](docs/errors.md) - error codes, the HTTP-status mapping, and recovery patterns.

## Quick Example

```objc
#import <Foundation/Foundation.h>
#import "MongrelDBClient.h"

int main(void) {
    @autoreleasepool {
        NSError *e = nil;
        MongrelDBClient *db = [MongrelDBClient connectWithURL:@"http://127.0.0.1:8453" error:&e];

        /* Create a table. */
        NSArray *cols = @[
            [MongrelDBColumn columnWithId:1 name:@"id" type:@"int64" primaryKey:YES isNullable:NO],
            [MongrelDBColumn columnWithId:2 name:@"customer" type:@"varchar" primaryKey:NO isNullable:NO],
            [MongrelDBColumn columnWithId:3 name:@"amount" type:@"float64" primaryKey:NO isNullable:NO],
        ];
        [db createTableWithName:@"orders" columns:cols error:&e];

        /* Insert rows. */
        [db putIntoTable:@"orders" cells:@[
            [MongrelDBInputCell cellWithColumnId:1 value:@1],
            [MongrelDBInputCell cellWithColumnId:2 value:@"Alice"],
            [MongrelDBInputCell cellWithColumnId:3 value:@99.50],
        ] idempotencyKey:nil error:&e];

        /* Query with a native index condition (learned-range index on an integer column). */
        MongrelDBCondition *cond = [[MongrelDBCondition alloc] init];
        cond.kind = MongrelDBConditionRange;
        cond.columnId = 1;
        cond.lo = 1; cond.loSet = YES;
        cond.hi = 100; cond.hiSet = YES;
        NSArray *rows = [db queryTable:@"orders" conditions:@[cond]
                            projection:nil limit:100 truncated:nil error:&e];
        NSLog(@"rows: %lu", (unsigned long)rows.count);

        int64_t n = [db countOfTable:@"orders" error:&e];
        NSLog(@"count: %lld", (long long)n); /* 1 */
    }
    return 0;
}
```

## Authentication

```objc
NSError *e = nil;

/* Bearer token (--auth-token mode) */
MongrelDBClient *db = [MongrelDBClient connectWithURL:@"http://127.0.0.1:8453"
                                                token:@"my-secret-token"
                                               error:&e];

/* HTTP Basic (--auth-users mode) */
MongrelDBClient *db2 = [MongrelDBClient connectWithURL:@"http://127.0.0.1:8453"
                                              username:@"admin"
                                              password:@"s3cret"
                                                 error:&e];
```

A token takes precedence over basic auth if both are supplied.

## Batch transactions

Operations are staged locally and committed atomically. The engine enforces
unique, foreign key, and check constraints at commit time.

```objc
NSArray *ops = @[
    @{@"put": @{@"table": @"orders", @"cells": @[@1, @10, @2, @"Dave", @3, @50.0], @"returning": @NO}},
    @{@"put": @{@"table": @"orders", @"cells": @[@1, @11, @2, @"Eve", @3, @75.0], @"returning": @NO}},
    @{@"delete_by_pk": @{@"table": @"orders", @"pk": @2}},
];

/* Atomic - all or nothing. The idempotency key makes it safe to retry. */
NSArray *results = [db transactionWithOps:ops idempotencyKey:@"batch-1" error:&e];
if (e && e.code == MongrelDBErrorConflict) {
    NSLog(@"constraint violated: %@", e.localizedDescription);
}
```

## Native query builder

Conditions push down to the engine's specialized indexes. Each `MongrelDBCondition`
targets one index; multiple conditions are AND-ed.

```objc
/* Bitmap equality (low-cardinality columns) */
MongrelDBCondition *bitmap = [[MongrelDBCondition alloc] init];
bitmap.kind = MongrelDBConditionBitmapEq;
bitmap.columnId = 2;
bitmap.value = @"Alice";

/* Range query on an integer column (learned-range index) */
MongrelDBCondition *range = [[MongrelDBCondition alloc] init];
range.kind = MongrelDBConditionRange;
range.columnId = 1;
range.lo = 1; range.loSet = YES;
range.hi = 100; range.hiSet = YES;

/* Range query on a float64 column */
MongrelDBCondition *rangeF64 = [[MongrelDBCondition alloc] init];
rangeF64.kind = MongrelDBConditionRangeF64;
rangeF64.columnId = 3;
rangeF64.loF64 = 10.5; rangeF64.loSet = YES; rangeF64.loInclusive = YES;
rangeF64.hiF64 = 99.99; rangeF64.hiSet = YES; rangeF64.hiInclusive = NO;

BOOL trunc = NO;
NSArray *rows = [db queryTable:@"orders" conditions:@[bitmap, range, rangeF64]
                    projection:@[@1, @3] limit:100 truncated:&trunc error:&e];
if (trunc) {
    /* result set hit the limit; more matches exist on the server */
}
```

## Schema constraints

Three optional fields on `MongrelDBColumn` let you set defaults and constrain
what goes into a column at create time. All are omitted from the wire JSON when
left nil, so existing schemas are unaffected.

```objc
MongrelDBColumn *statusCol = [[MongrelDBColumn alloc] init];
statusCol.columnId = 3;
statusCol.name = @"status";
statusCol.type = @"enum";
statusCol.primaryKey = NO;
statusCol.isNullable = NO;
/* Wire emit: "enum_variants": ["active","inactive","paused"] */
statusCol.enumVariants = @[@"active", @"inactive", @"paused"];
statusCol.defaultValue = @"active"; /* must be one of the enum variants */
MongrelDBColumn *createdAt = [MongrelDBColumn columnWithId:4
    name:@"created_at" type:@"timestamp_nanos" primaryKey:NO isNullable:NO];
createdAt.defaultExpression = @"now"; /* dynamic default evaluated on insert */

MongrelDBColumn *literalNow = [MongrelDBColumn columnWithId:5
    name:@"literal_now" type:@"varchar" primaryKey:NO isNullable:NO];
literalNow.defaultValueJSON = @"now"; /* literal static string, not dynamic */

MongrelDBColumn *literalUuid = [MongrelDBColumn columnWithId:6
    name:@"literal_uuid" type:@"varchar" primaryKey:NO isNullable:NO];
literalUuid.defaultValueJSON = @"uuid"; /* literal static string */

NSDictionary *constraints = @{
    @"checks": @[@{@"id": @1, @"name": @"id_present",
                     @"expr": @{@"IsNotNull": @1}}],
};
[db createTableWithName:@"orders" columns:@[statusCol, createdAt, literalNow, literalUuid]
            constraints:constraints error:&e];
```

`enumVariants` is an `NSArray<NSString *> *`; nil means "absent". `defaultValue`
is a legacy string constant; `defaultValueJSON` is a typed JSON scalar
(`NSString`, `NSNumber`, `NSNull`, or `@YES`/`@NO`). `defaultExpression` is the
only dynamic discriminator and accepts `"now"` or `"uuid"`. If you need the
literal strings `"now"` or `"uuid"` as static defaults, set them through
`defaultValueJSON`; using `defaultExpression` makes them dynamic. The constraint
is enforced server-side, so a row whose value falls outside the listed variants
surfaces as `MongrelDBErrorConflict` on `putIntoTable:` / `transactionWithOps:`.

## SQL

```objc
[db sql:@"INSERT INTO orders (id, customer, amount) VALUES (99, 'Zoe', 999.0)" error:&e];
[db sql:@"CREATE TABLE archive AS SELECT * FROM orders WHERE amount > 500" error:&e];

/* Recursive CTEs and window functions */
[db sql:@"WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM r WHERE n<10) "
        "SELECT n FROM r" error:&e];
[db sql:@"SELECT id, ROW_NUMBER() OVER (PARTITION BY customer ORDER BY amount DESC) "
        "FROM orders" error:&e];
```

DDL and DML statements return an empty JSON array (`@[]`) on success; `SELECT`
returns an array of row objects.

## Error handling

Every method takes an `NSError **` out-parameter. Check the error's code in the
`MongrelDBErrorDomain` domain to branch on the category of failure.

```objc
NSDictionary *body = [db schemaForTable:@"missing_table" error:&e];
if (e) {
    switch (e.code) {
        case MongrelDBErrorNotFound:
            NSLog(@"not found: %@", e.localizedDescription);
            break;
        case MongrelDBErrorConflict:
            NSLog(@"constraint: %@", e.localizedDescription);
            break;
        case MongrelDBErrorAuth:
            NSLog(@"not authorized: %@", e.localizedDescription);
            break;
        case MongrelDBErrorNetwork:
            NSLog(@"can't reach daemon: %@", e.localizedDescription);
            break;
        default:
            NSLog(@"error: %@", e.localizedDescription);
            break;
    }
    e = nil;
}
```

## API reference

### Client lifecycle

| Method / Property | Description |
|-------------------|-------------|
| `connectWithURL:error:` | Construct a client (nil url defaults to `http://127.0.0.1:8453`) |
| `connectWithURL:token:error:` | Bearer token auth (`--auth-token` mode) |
| `connectWithURL:username:password:error:` | HTTP Basic auth (`--auth-users` mode) |
| `setTimeout:` | Per-request timeout (default 30) |
| `lastError` | Message for the most recent failure |
| `lastEpoch` | Epoch of the most recent successful `/kit/txn` commit (read/write) |

### Database operations

| Method | Description |
|--------|-------------|
| `health:` | Check daemon health |
| `tableNames:` | List table names |
| `createTableWithName:columns:error:` | Create a table |
| `createTableWithName:columns:constraints:error:` | Create a table with check constraints |
| `dropTableWithName:error:` | Drop a table |
| `countOfTable:error:` | Row count |
| `putIntoTable:cells:idempotencyKey:error:` | Insert a row |
| `upsertIntoTable:cells:updateCells:idempotencyKey:error:` | Upsert a row |
| `deleteFromTable:rowId:error:` | Delete by row id |
| `deleteFromTable:primaryKeyValue:error:` | Delete by primary key |
| `transactionWithOps:idempotencyKey:error:` | Commit a batch atomically |
| `queryTable:conditions:projection:limit:truncated:error:` | Run a native query |
| `queryTable:conditions:projection:limit:offset:truncated:error:` | Run a paged native query |
| `sql:error:` | Execute SQL |
| `schema:error:` | Full schema catalog |
| `schemaForTable:error:` | Single-table descriptor |
| `setHistoryRetentionEpochs:error:` | Set the history retention window |
| `historyRetentionEpochs:` | Get the current retention window |
| `earliestRetainedEpoch:` | Get the oldest readable epoch |

## History retention

Control how far back time-travel queries can read. The window is measured in
epochs (monotonically increasing commit numbers).

```objc
NSError *e = nil;
NSDictionary *result = [db setHistoryRetentionEpochs:1000 error:&e];
NSLog(@"window: %llu", [result[@"history_retention_epochs"] unsignedLongLongValue]);
NSLog(@"earliest: %llu", [result[@"earliest_retained_epoch"] unsignedLongLongValue]);

NSLog(@"window: %llu", [db historyRetentionEpochs:&e]);
NSLog(@"earliest: %llu", [db earliestRetainedEpoch:&e]);

/* Each successful batch commit updates db.lastEpoch. */
NSArray *ops = @[
    @{@"put": @{@"table": @"orders", @"cells": @[@1, @99, @2, @"Alice"], @"returning": @NO}},
];
[db transactionWithOps:ops idempotencyKey:nil error:&e];
uint64_t committedEpoch = db.lastEpoch;

/* Read the row as it existed right after that commit. */
NSString *sql = [NSString stringWithFormat:@"SELECT customer FROM orders AS OF EPOCH %llu WHERE id = 1",
                 (unsigned long long)committedEpoch];
NSArray *rows = [db sql:sql error:&e];
```

Raising retention prevents history from being garbage collected, but it cannot
restore epochs that have already been pruned. These endpoints require admin
privileges when the daemon runs with auth enabled.

## Building and testing

```sh
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build

# Run the live test suite. Set MONGRELDB_URL to use an already-running daemon.
# Tests self-skip when no daemon is reachable.
ctest --test-dir build --output-on-failure
```

Fetch a prebuilt server binary from the [MongrelDB releases](https://github.com/visorcraft/MongrelDB/releases):

```sh
mkdir -p bin
# For Apple Silicon use mongreldb-server-darwin-arm64; for Intel use mongreldb-server-darwin-x64.
curl -fsSL -o bin/mongreldb-server \
  https://github.com/visorcraft/MongrelDB/releases/download/v0.50.0/mongreldb-server-darwin-arm64
chmod +x bin/mongreldb-server
```

### Linking against the client

```sh
clang -fobjc-arc -I/path/to/MongrelDB-ObjC/src your_app.m \
  /path/to/MongrelDB-ObjC/src/MongrelDBClient.m \
  /path/to/MongrelDB-ObjC/src/MongrelDBError.m \
  -framework Foundation -o your_app
```

## Contributing

Contributions are welcome. Please:

1. Open an issue first for non-trivial changes.
2. Add focused tests near your change - the suite must stay green.
3. Keep the code Objective-C ARC, warning-clean under `-Wall -Wextra`.
4. Match the existing style: 4-space indent, Objective-C naming conventions.

## License

Dual-licensed under the **MIT License** or the **Apache License, Version 2.0**,
at your option. See [MIT](LICENSE-MIT) OR [Apache-2.0](LICENSE-APACHE) for the full text.

`SPDX-License-Identifier: MIT OR Apache-2.0`
