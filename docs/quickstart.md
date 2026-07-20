# Quickstart

Zero to a running MongrelDB Objective-C program in fifteen minutes. This guide
assumes a fresh macOS machine and walks through installing the prerequisites,
starting the daemon, and writing, running, and understanding a complete program.

---

## 1. Prerequisites

You need three things installed: clang (Apple LLVM), CMake, and a
`mongreldb-server` daemon.

### Install a compiler and CMake

On macOS, install the Xcode Command Line Tools and CMake:

```sh
xcode-select --install
brew install cmake
```

Verify:

```sh
clang --version
cmake --version   # >= 3.16
```

### Install mongreldb-server

Fetch a prebuilt server binary from the
[MongrelDB releases](https://github.com/visorcraft/MongrelDB/releases):

```sh
mkdir -p bin
# For Apple Silicon use mongreldb-server-darwin-arm64; for Intel use mongreldb-server-darwin-x64.
curl -fsSL -o bin/mongreldb-server \
  https://github.com/visorcraft/MongrelDB/releases/download/v0.61.1/mongreldb-server-darwin-arm64
chmod +x bin/mongreldb-server
```

Verify it runs:

```sh
./bin/mongreldb-server --version
```

## 2. Start the daemon

By default `mongreldb-server` listens on `http://127.0.0.1:8453` and stores
data in the directory you pass as its first argument.

```sh
mkdir -p /tmp/mdb-data
/path/to/mongreldb-server /tmp/mdb-data
```

In another terminal, sanity-check it:

```sh
curl http://127.0.0.1:8453/health
# ok
```

Leave the daemon running for the rest of this guide.

## 3. Create a project and build the client

```sh
mkdir mdb-demo && cd mdb-demo
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build
```

## 4. Write your first program

Create `demo.m`:

```objc
#import <Foundation/Foundation.h>
#import "MongrelDBClient.h"

int main(void) {
    @autoreleasepool {
        NSError *e = nil;

        /* 1. Connect to the daemon. nil falls back to http://127.0.0.1:8453. */
        MongrelDBClient *db = [MongrelDBClient connectWithURL:nil error:&e];

        /* 2. Health check before doing anything else. */
        if (![db health:&e]) {
            NSLog(@"daemon not reachable: %@", e.localizedDescription);
            return 1;
        }

        /* 3. Create a table. Optional schema fields:
         *    - enumVariants: a fixed set of allowed values for a text column
         *      (server-enforced on commit).
         *    - defaultValue: a legacy string default.
         *    - defaultValueJSON: a typed JSON scalar default (NSString, NSNumber,
         *      NSNull, @YES/@NO). Use this for literal strings such as "now" or
         *      "uuid"; defaultExpression would make those dynamic instead.
         *    - defaultExpression: dynamic default, only "now" or "uuid".
         *    All are nil = absent and are dropped from the wire JSON when not
         *    set, so the existing positional form stays valid. */
        MongrelDBColumn *c4 = [[MongrelDBColumn alloc] init];
        c4.columnId = 4; c4.name = @"status"; c4.type = @"enum";
        c4.primaryKey = NO; c4.isNullable = NO;
        c4.enumVariants = @[@"active", @"inactive", @"paused"];
        c4.defaultValue = @"active";
        NSArray *cols = @[
            [MongrelDBColumn columnWithId:1 name:@"id" type:@"int64" primaryKey:YES isNullable:NO],
            [MongrelDBColumn columnWithId:2 name:@"customer" type:@"varchar" primaryKey:NO isNullable:NO],
            [MongrelDBColumn columnWithId:3 name:@"amount" type:@"float64" primaryKey:NO isNullable:NO],
            c4,
        ];
        [db createTableWithName:@"orders" columns:cols error:&e];

        /* 4. Insert rows. The status column is constrained to the enum set. */
        [db putIntoTable:@"orders" cells:@[
            [MongrelDBInputCell cellWithColumnId:1 value:@1],
            [MongrelDBInputCell cellWithColumnId:2 value:@"Alice"],
            [MongrelDBInputCell cellWithColumnId:3 value:@99.5],
            [MongrelDBInputCell cellWithColumnId:4 value:@"active"],
        ] idempotencyKey:nil error:&e];

        /* 5. Query with a native index condition on an integer column. */
        MongrelDBCondition *cond = [[MongrelDBCondition alloc] init];
        cond.kind = MongrelDBConditionRange;
        cond.columnId = 1;
        cond.lo = 1; cond.loSet = YES;
        cond.hi = 100; cond.hiSet = YES;
        NSArray *rows = [db queryTable:@"orders" conditions:@[cond]
                            projection:@[@1, @2] limit:100 truncated:nil error:&e];
        NSLog(@"rows: %lu", (unsigned long)rows.count);

        /* 6. Count the rows. */
        int64_t n = [db countOfTable:@"orders" error:&e];
        NSLog(@"total rows: %lld", (long long)n);
    }
    return 0;
}
```

Build and run it:

```sh
clang -fobjc-arc -Isrc demo.m src/MongrelDBClient.m src/MongrelDBError.m \
  -framework Foundation -o demo
./demo
```

You should see the row count of 1.

## 5. What each part does

| Code | What it does |
|------|--------------|
| `connectWithURL:error:` | Builds an HTTP client targeting one daemon. |
| `health:` | GET `/health`; returns YES when the daemon answers. |
| `createTableWithName:columns:error:` | POST `/kit/create_table`. Column `columnId`s are the on-wire identifiers. |
| `col.enumVariants` | Optional. Constrains a text column to a fixed value set; server-enforced on commit, surfaces as `MongrelDBErrorConflict`. nil = absent. |
| `col.defaultValue` | Optional. Default value string for the column. nil = absent. |
| `putIntoTable:cells:idempotencyKey:error:` | Single-op transaction: POST `/kit/txn` with one `put` op. `cells` is flattened to `[col_id, val, ...]`. |
| `queryTable:...` | Builds a `/kit/query` body. Conditions push down to native indexes. |
| `projection:@[@1,@2]` | Server returns only those column ids, saving bandwidth. |
| `limit:100` | Caps the result; check the `truncated` out-param afterward. |
| `countOfTable:error:` | GET `/tables/{name}/count`. |
| `setHistoryRetentionEpochs:error:` | PUT `/history/retention`; controls time-travel query depth. |
| `lastEpoch` | Epoch of the most recent successful `/kit/txn` commit; use with `AS OF EPOCH`. |

## 6. History retention and time travel

`setHistoryRetentionEpochs:error:` sets how many epochs of history the daemon
keeps. Every successful batch commit updates the client's `lastEpoch` property
with the epoch assigned by the server.

```objc
NSError *e = nil;
[db setHistoryRetentionEpochs:1000 error:&e];

/* Insert a row. */
[db putIntoTable:@"orders"
            cells:@[[MongrelDBInputCell cellWithColumnId:1 value:@1],
                    [MongrelDBInputCell cellWithColumnId:2 value:@"Alice"]]
   idempotencyKey:nil error:&e];
uint64_t epoch = db.lastEpoch;

/* Update it later. */
[db putIntoTable:@"orders"
            cells:@[[MongrelDBInputCell cellWithColumnId:1 value:@1],
                    [MongrelDBInputCell cellWithColumnId:2 value:@"Alicia"]]
   idempotencyKey:nil error:&e];

/* Read the row as it existed right after the first commit. */
NSString *sql = [NSString stringWithFormat:
    @"SELECT customer FROM orders AS OF EPOCH %llu WHERE id = 1",
    (unsigned long long)epoch];
NSArray *rows = [db sql:sql error:&e];
```

Raising the window prevents older epochs from being garbage collected, but it
cannot bring back epochs that have already been pruned.

## 7. Common pitfalls

**Using the column name instead of the column id.** Every on-wire API uses the
numeric `columnId` from `createTableWithName:`, never the `name`. Conditions
take the numeric `columnId`, not the string name.

**Treating a single `putIntoTable:` as non-transactional.** `put` is a one-op
transaction. A unique constraint violation surfaces as `MongrelDBErrorConflict`
(HTTP 409), not as a silent no-op.

**Expecting `sql:error:` to always return rows.** The `/sql` endpoint streams
Arrow IPC for `SELECT` in most builds, so `sql:` returns the decoded JSON when
the server honors `format:json`, or nil for non-JSON bodies. Use it for
DDL/DML and statements whose success is the signal.

**Pointing at a daemon that requires auth.** If the daemon was started with
`--auth-token` or `--auth-users`, every call fails with `MongrelDBErrorAuth`
unless you use `connectWithURL:token:error:` or
`connectWithURL:username:password:error:`. See [auth.md](auth.md).

**Assuming `enumVariants` is checked client-side.** The ObjC client only emits
the constraint in the wire JSON; the engine enforces it on `put` / `commit` and
returns `MongrelDBErrorConflict` for any value outside the set. Validate at the
edge if you need faster feedback.

## Next steps

- [transactions.md](transactions.md) - atomic batches, idempotency, retries
- [queries.md](queries.md) - every native index condition
- [sql.md](sql.md) - recursive CTEs, window functions, `CREATE TABLE AS SELECT`
- [auth.md](auth.md) - bearer tokens, basic auth, user/role management
- [errors.md](errors.md) - the full error code set and recovery patterns
