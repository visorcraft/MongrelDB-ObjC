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
  <a href="https://github.com/visorcraft/MongrelDB/releases"><img src="https://img.shields.io/badge/server-v0.46.2-blue.svg" alt="MongrelDB server" /></a>
  <a href="#license"><img src="https://img.shields.io/badge/license-MIT%20OR%20Apache--2.0-blue.svg" alt="License" /></a>
</p>

## Package

| Surface | Package | Install |
|---|---|---|
| Objective-C client | `MongrelDB-ObjC` | build from source with CMake + Apple frameworks |

## Requirements

- **A Objective-C compiler** (clang, Apple LLVM) on macOS
- **Apple Foundation** (NSURLSession, NSJSONSerialization) - ships with macOS/iOS
- **CMake 3.16 or newer** (to build)
- A running [`mongreldb-server`](https://github.com/visorcraft/MongrelDB) daemon

## What It Provides

- **Typed CRUD** over the Kit transaction endpoint: `putIntoTable:cells:`, `upsertIntoTable:cells:updateCells:` (insert-or-update on PK conflict), `deleteFromTable:rowId:` and `deleteFromTable:primaryKeyValue:`, with idempotency keys for safe retries.
- **Query builder** that pushes conditions down to the engine's specialized indexes for sub-millisecond lookups: bitmap equality, learned-range, null checks, and FM-index full-text search. Conditions are AND-ed.
- **Idempotent batch transactions** - all operations staged locally and committed atomically, with the engine enforcing unique, foreign key, and check constraints at commit time. Idempotency keys return the original response on duplicate commits, even after a crash.
- **Full SQL access** through the DataFusion-backed `/sql` endpoint: recursive CTEs, window functions, `CREATE TABLE AS SELECT`, materialized views, and multi-statement execution.
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
            [MongrelDBColumn columnWithId:1 name:@"id" type:@"int64" primaryKey:YES nullable:NO],
            [MongrelDBColumn columnWithId:2 name:@"customer" type:@"varchar" primaryKey:NO nullable:NO],
            [MongrelDBColumn columnWithId:3 name:@"amount" type:@"float64" primaryKey:NO nullable:NO],
        ];
        [db createTableWithName:@"orders" columns:cols error:&e];

        /* Insert rows. */
        [db putIntoTable:@"orders" cells:@[
            [MongrelDBInputCell cellWithColumnId:1 value:@1],
            [MongrelDBInputCell cellWithColumnId:2 value:@"Alice"],
            [MongrelDBInputCell cellWithColumnId:3 value:@99.50],
        ] idempotencyKey:nil error:&e];

        /* Query with a native index condition (learned-range index). */
        MongrelDBCondition *cond = [[MongrelDBCondition alloc] init];
        cond.kind = MongrelDBConditionRange;
        cond.columnId = 3;
        cond.lo = 100.0; cond.loSet = YES;
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

/* Range query (learned-range index) */
MongrelDBCondition *range = [[MongrelDBCondition alloc] init];
range.kind = MongrelDBConditionRange;
range.columnId = 3;
range.lo = 50.0; range.loSet = YES;
range.hi = 150.0; range.hiSet = YES;

BOOL trunc = NO;
NSArray *rows = [db queryTable:@"orders" conditions:@[bitmap, range]
                    projection:@[@1, @3] limit:100 truncated:&trunc error:&e];
if (trunc) {
    /* result set hit the limit; more matches exist on the server */
}
```

## Schema constraints

Two optional fields on `MongrelDBColumn` let you constrain what goes into a
column at create time. Both are omitted from the wire JSON when left nil, so
existing schemas are unaffected.

```objc
MongrelDBColumn *statusCol = [[MongrelDBColumn alloc] init];
statusCol.columnId = 3;
statusCol.name = @"status";
statusCol.type = @"varchar";
statusCol.primaryKey = NO;
statusCol.nullable = NO;
/* Wire emit: "enum_variants": ["active","inactive","paused"] */
statusCol.enumVariants = @[@"active", @"inactive", @"paused"];
/* Wire emit: "default_value": "active" */
statusCol.defaultValue = @"active";
```

`enumVariants` is an `NSArray<NSString *> *`; nil means "absent". `defaultValue`
is a single string constant; nil means "absent". The constraint is enforced
server-side, so a row whose value falls outside the listed variants surfaces
as `MongrelDBErrorConflict` on `putIntoTable:` / `transactionWithOps:`.

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

| Method | Description |
|--------|-------------|
| `connectWithURL:error:` | Construct a client (nil url defaults to `http://127.0.0.1:8453`) |
| `connectWithURL:token:error:` | Bearer token auth (`--auth-token` mode) |
| `connectWithURL:username:password:error:` | HTTP Basic auth (`--auth-users` mode) |
| `setTimeout:` | Per-request timeout (default 30) |
| `lastError` | Message for the most recent failure |

### Database operations

| Method | Description |
|--------|-------------|
| `health:` | Check daemon health |
| `tableNames:` | List table names |
| `createTableWithName:columns:error:` | Create a table |
| `dropTableWithName:error:` | Drop a table |
| `countOfTable:error:` | Row count |
| `putIntoTable:cells:idempotencyKey:error:` | Insert a row |
| `upsertIntoTable:cells:updateCells:idempotencyKey:error:` | Upsert a row |
| `deleteFromTable:rowId:error:` | Delete by row id |
| `deleteFromTable:primaryKeyValue:error:` | Delete by primary key |
| `transactionWithOps:idempotencyKey:error:` | Commit a batch atomically |
| `queryTable:conditions:projection:limit:truncated:error:` | Run a native query |
| `sql:error:` | Execute SQL |
| `schema:error:` | Full schema catalog |
| `schemaForTable:error:` | Single-table descriptor |

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
curl -fsSL -o bin/mongreldb-server \
  https://github.com/visorcraft/MongrelDB/releases/download/v0.46.2/mongreldb-server-macos-x64
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
