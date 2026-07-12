/*
 * test_mongreldb.m - live integration tests for the MongrelDB ObjC client.
 *
 * These exercise the full client surface against a running mongreldb-server
 * daemon. They self-skip (print SKIP and pass) when no daemon is reachable.
 *
 * Point at an already-running daemon with the MONGRELDB_URL environment
 * variable. By default this connects to http://127.0.0.1:8453.
 *
 * The 16-operation conformance matrix mirrors the other official clients:
 * health, create_table, count, put, upsert, query (pk), query (range),
 * transaction (batch commit), delete_by_pk, delete (by row id), string values,
 * sql, table_names, schema_for, error not_found, idempotency_key, history
 * retention.
 *
 * Licensing: MIT OR Apache-2.0.
 */

#import <Foundation/Foundation.h>
#import "MongrelDBClient.h"

/* ── Tiny test framework ───────────────────────────────────────────────── */

static int g_pass = 0;
static int g_fail = 0;
static int g_skip = 0;

#define FAIL(...)                                                              \
    do {                                                                       \
        fprintf(stderr, "  FAIL %s:%d: ", __FILE__, __LINE__);                 \
        NSLog(__VA_ARGS__);                                                    \
        g_fail++;                                                              \
    } while (0)

#define SKIP(reason)                                                           \
    do {                                                                       \
        printf("  SKIP: %s\n", reason ? reason : "(no daemon)");               \
        g_skip++;                                                              \
        return;                                                                \
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

/* ── Daemon harness ────────────────────────────────────────────────────── */

static MongrelDBClient *g_client = nil;
static BOOL g_have_daemon = NO;

static MongrelDBClient *connectClient(NSString *url, NSError **error) {
    return [MongrelDBClient connectWithURL:url error:error];
}

static BOOL daemonHealthy(NSString *url) {
    NSError *e = nil;
    MongrelDBClient *c = connectClient(url, &e);
    if (!c) {
        return NO;
    }
    BOOL ok = [c health:&e];
    return ok;
}

static void setupDaemon(void) {
    NSString *url = [NSProcessInfo.processInfo.environment objectForKey:@"MONGRELDB_URL"];
    if (url.length == 0) {
        url = @"http://127.0.0.1:8453";
    }
    if (!daemonHealthy(url)) {
        fprintf(stderr, "--- no mongreldb-server reachable at %s; live tests skipped\n",
                url.UTF8String);
        return;
    }
    NSError *e = nil;
    g_client = connectClient(url, &e);
    if (g_client) {
        g_have_daemon = YES;
    }
}

#define SKIP_IF_NO_DAEMON()                                                    \
    do {                                                                       \
        if (!g_have_daemon) {                                                  \
            SKIP("no mongreldb-server available");                             \
        }                                                                      \
    } while (0)

/* ── Helpers ───────────────────────────────────────────────────────────── */

static MongrelDBColumn *intCol(uint16_t id, NSString *name, BOOL pk) {
    return [MongrelDBColumn columnWithId:id name:name type:@"int64"
                             primaryKey:pk isNullable:!pk];
}

static MongrelDBColumn *floatCol(uint16_t id, NSString *name) {
    return [MongrelDBColumn columnWithId:id name:name type:@"float64"
                             primaryKey:NO isNullable:NO];
}

static MongrelDBColumn *varcharCol(uint16_t id, NSString *name) {
    MongrelDBColumn *c = [[MongrelDBColumn alloc] init];
    c.columnId = id;
    c.name = name;
    c.type = @"varchar";
    c.primaryKey = NO;
    c.isNullable = NO;
    return c;
}

static MongrelDBInputCell *i64Cell(uint16_t col, int64_t v) {
    return [MongrelDBInputCell cellWithColumnId:col value:@(v)];
}

static MongrelDBInputCell *f64Cell(uint16_t col, double v) {
    return [MongrelDBInputCell cellWithColumnId:col value:@(v)];
}

static MongrelDBInputCell *strCell(uint16_t col, NSString *v) {
    return [MongrelDBInputCell cellWithColumnId:col value:v];
}

/* Drop-then-create so a fresh table is ready for the test. Ignores not-found. */
static void freshTable(NSString *name, NSArray<MongrelDBColumn *> *cols) {
    NSError *e = nil;
    [g_client dropTableWithName:name error:&e]; /* ignore not-found */
    e = nil;
    [g_client createTableWithName:name columns:cols error:&e];
    if (e) {
        FAIL(@"create_table %@: %@", name, e.localizedDescription);
    }
}

/* Look up a value for a column id in a query row. Returns the NSNumber or nil. */
static id rowValue(NSDictionary *row, int64_t colId) {
    id v = [row objectForKey:@(colId)];
    return v;
}

/* ── Tests (16-operation conformance matrix) ───────────────────────────── */

/* 1. health */
static void test_health(void) {
    SKIP_IF_NO_DAEMON();
    NSError *e = nil;
    BOOL ok = [g_client health:&e];
    CHECK(ok, @"health failed: %@", e.localizedDescription);
}

/* 2. create_table + count */
static void test_create_table_and_count(void) {
    SKIP_IF_NO_DAEMON();
    NSArray *cols = @[intCol(1, @"id", YES), floatCol(2, @"amount")];
    freshTable(@"objc_tbl_count", cols);
    NSError *e = nil;
    int64_t n = [g_client countOfTable:@"objc_tbl_count" error:&e];
    CHECK(e == nil, @"count failed: %@", e.localizedDescription);
    CHECK(n == 0, @"expected 0 rows, got %lld", (long long)n);
}

/* 3. put + count */
static void test_put_and_count(void) {
    SKIP_IF_NO_DAEMON();
    NSArray *cols = @[intCol(1, @"id", YES), floatCol(2, @"amount")];
    freshTable(@"objc_put", cols);
    NSError *e = nil;
    NSArray *r1 = @[i64Cell(1, 1), f64Cell(2, 99.5)];
    NSArray *r2 = @[i64Cell(1, 2), f64Cell(2, 150.0)];
    BOOL ok = [g_client putIntoTable:@"objc_put" cells:r1 idempotencyKey:nil error:&e];
    CHECK(ok && e == nil, @"put r1 failed: %@", e.localizedDescription);
    ok = [g_client putIntoTable:@"objc_put" cells:r2 idempotencyKey:nil error:&e];
    CHECK(ok && e == nil, @"put r2 failed: %@", e.localizedDescription);
    int64_t n = [g_client countOfTable:@"objc_put" error:&e];
    CHECK(n == 2, @"expected 2 rows, got %lld", (long long)n);
}

/* 4. upsert (update on conflict) */
static void test_upsert(void) {
    SKIP_IF_NO_DAEMON();
    NSArray *cols = @[intCol(1, @"id", YES), floatCol(2, @"amount")];
    freshTable(@"objc_upsert", cols);
    NSError *e = nil;
    NSArray *r1 = @[i64Cell(1, 1), f64Cell(2, 10.0)];
    [g_client putIntoTable:@"objc_upsert" cells:r1 idempotencyKey:nil error:&e];
    CHECK(e == nil, @"put failed: %@", e.localizedDescription);

    /* Upsert same PK with update on conflict. */
    NSArray *up = @[i64Cell(1, 1), f64Cell(2, 20.0)];
    NSArray *upd = @[f64Cell(2, 20.0)];
    [g_client upsertIntoTable:@"objc_upsert" cells:up updateCells:upd idempotencyKey:nil error:&e];
    CHECK(e == nil, @"upsert failed: %@", e.localizedDescription);
    int64_t n = [g_client countOfTable:@"objc_upsert" error:&e];
    CHECK(n == 1, @"expected 1 row after upsert, got %lld", (long long)n);

    /* Query back and verify the updated value. */
    MongrelDBCondition *cond = [[MongrelDBCondition alloc] init];
    cond.kind = MongrelDBConditionPK;
    cond.value = @(1);
    NSArray *rows = [g_client queryTable:@"objc_upsert" conditions:@[cond]
                               projection:nil limit:0 truncated:nil error:&e];
    CHECK(e == nil, @"query failed: %@", e.localizedDescription);
    CHECK(rows.count == 1, @"expected 1 row from pk query, got %lu", (unsigned long)rows.count);
    NSNumber *amt = rowValue(rows[0], 2);
    CHECK([amt doubleValue] == 20.0, @"expected updated amount 20.0, got %@", amt);
}

/* 5. query by primary key */
static void test_query_by_pk(void) {
    SKIP_IF_NO_DAEMON();
    NSArray *cols = @[intCol(1, @"id", YES)];
    freshTable(@"objc_pk", cols);
    NSError *e = nil;
    [g_client putIntoTable:@"objc_pk" cells:@[i64Cell(1, 42)] idempotencyKey:nil error:&e];
    [g_client putIntoTable:@"objc_pk" cells:@[i64Cell(1, 43)] idempotencyKey:nil error:&e];
    CHECK(e == nil, @"put failed: %@", e.localizedDescription);

    MongrelDBCondition *cond = [[MongrelDBCondition alloc] init];
    cond.kind = MongrelDBConditionPK;
    cond.value = @(42);
    NSArray *rows = [g_client queryTable:@"objc_pk" conditions:@[cond]
                               projection:nil limit:0 truncated:nil error:&e];
    CHECK(e == nil, @"query failed: %@", e.localizedDescription);
    CHECK(rows.count == 1, @"expected 1 row, got %lu", (unsigned long)rows.count);
    NSNumber *pk = rowValue(rows[0], 1);
    CHECK([pk longLongValue] == 42, @"expected returned pk 42, got %@", pk);
}

/* 6. query by range */
static void test_query_range(void) {
    SKIP_IF_NO_DAEMON();
    NSArray *cols = @[intCol(1, @"id", YES), intCol(2, @"amount", NO)];
    freshTable(@"objc_range", cols);
    NSError *e = nil;
    [g_client putIntoTable:@"objc_range" cells:@[i64Cell(1, 1), i64Cell(2, 50)] idempotencyKey:nil error:&e];
    [g_client putIntoTable:@"objc_range" cells:@[i64Cell(1, 2), i64Cell(2, 120)] idempotencyKey:nil error:&e];
    [g_client putIntoTable:@"objc_range" cells:@[i64Cell(1, 3), i64Cell(2, 200)] idempotencyKey:nil error:&e];
    CHECK(e == nil, @"put failed: %@", e.localizedDescription);

    MongrelDBCondition *cond = [[MongrelDBCondition alloc] init];
    cond.kind = MongrelDBConditionRange;
    cond.columnId = 2;
    cond.lo = 100; cond.loSet = YES;
    cond.hi = 150; cond.hiSet = YES;
    BOOL trunc = NO;
    NSArray *rows = [g_client queryTable:@"objc_range" conditions:@[cond]
                               projection:nil limit:0 truncated:&trunc error:&e];
    CHECK(e == nil, @"range query failed: %@", e.localizedDescription);
    CHECK(rows.count == 1, @"expected exactly 1 matching row, got %lu", (unsigned long)rows.count);
    CHECK(trunc == NO, @"result should not be truncated");
    NSNumber *pk = rowValue(rows[0], 1);
    CHECK([pk longLongValue] == 2, @"expected returned pk 2, got %@", pk);
}

/* 7. transaction (batch commit) */
static void test_transaction_commit(void) {
    SKIP_IF_NO_DAEMON();
    NSArray *cols = @[intCol(1, @"id", YES)];
    freshTable(@"objc_txn", cols);
    NSError *e = nil;
    NSArray *ops = @[
        @{@"put": @{@"table": @"objc_txn", @"cells": @[@(1), @(1)], @"returning": @NO}},
        @{@"put": @{@"table": @"objc_txn", @"cells": @[@(1), @(2)], @"returning": @NO}},
        @{@"put": @{@"table": @"objc_txn", @"cells": @[@(1), @(3)], @"returning": @NO}},
    ];
    NSArray *results = [g_client transactionWithOps:ops idempotencyKey:nil error:&e];
    CHECK(e == nil, @"commit failed: %@", e.localizedDescription);
    (void)results;
    int64_t n = [g_client countOfTable:@"objc_txn" error:&e];
    CHECK(n == 3, @"expected 3 rows after commit, got %lld", (long long)n);
}

/* 8. delete_by_pk */
static void test_delete_by_pk(void) {
    SKIP_IF_NO_DAEMON();
    NSArray *cols = @[intCol(1, @"id", YES)];
    freshTable(@"objc_del", cols);
    NSError *e = nil;
    [g_client putIntoTable:@"objc_del" cells:@[i64Cell(1, 5)] idempotencyKey:nil error:&e];
    int64_t n = [g_client countOfTable:@"objc_del" error:&e];
    CHECK(n == 1, @"expected 1 row, got %lld", (long long)n);
    [g_client deleteFromTable:@"objc_del" primaryKeyValue:@(5) error:&e];
    CHECK(e == nil, @"delete_by_pk failed: %@", e.localizedDescription);
    n = [g_client countOfTable:@"objc_del" error:&e];
    CHECK(n == 0, @"expected 0 rows after delete, got %lld", (long long)n);
}

/* 9. delete by row id */
static void test_delete_by_row_id(void) {
    SKIP_IF_NO_DAEMON();
    NSArray *cols = @[intCol(1, @"id", YES)];
    freshTable(@"objc_delrow", cols);
    NSError *e = nil;
    [g_client putIntoTable:@"objc_delrow" cells:@[i64Cell(1, 7)] idempotencyKey:nil error:&e];
    CHECK(e == nil, @"put failed: %@", e.localizedDescription);
    /* Query to find the row_id. The server includes a `row_id` key in every
     * native query row. */
    MongrelDBCondition *cond = [[MongrelDBCondition alloc] init];
    cond.kind = MongrelDBConditionPK;
    cond.value = @(7);
    NSArray *rows = [g_client queryTable:@"objc_delrow" conditions:@[cond]
                               projection:nil limit:0 truncated:nil error:&e];
    CHECK(e == nil, @"query failed: %@", e.localizedDescription);
    CHECK(rows.count == 1, @"expected 1 row, got %lu", (unsigned long)rows.count);
    NSNumber *rowId = rows[0][@"row_id"];
    CHECK(rowId != nil, @"row_id missing from query row");
    [g_client deleteFromTable:@"objc_delrow" rowId:rowId.unsignedLongLongValue error:&e];
    CHECK(e == nil, @"delete(rowId) failed: %@", e.localizedDescription);
    int64_t n = [g_client countOfTable:@"objc_delrow" error:&e];
    CHECK(n == 0, @"expected 0 rows after delete by row id, got %lld", (long long)n);
}

/* 10. string values round-trip */
static void test_string_values(void) {
    SKIP_IF_NO_DAEMON();
    NSArray *cols = @[intCol(1, @"id", YES), varcharCol(2, @"label"), floatCol(3, @"amount")];
    freshTable(@"objc_str", cols);
    NSError *e = nil;
    [g_client putIntoTable:@"objc_str"
                     cells:@[i64Cell(1, 1), strCell(2, @"hello world"), f64Cell(3, 1.5)]
            idempotencyKey:nil error:&e];
    CHECK(e == nil, @"put failed: %@", e.localizedDescription);

    MongrelDBCondition *cond = [[MongrelDBCondition alloc] init];
    cond.kind = MongrelDBConditionPK;
    cond.value = @(1);
    NSArray *rows = [g_client queryTable:@"objc_str" conditions:@[cond]
                               projection:nil limit:0 truncated:nil error:&e];
    CHECK(e == nil, @"query failed: %@", e.localizedDescription);
    CHECK(rows.count == 1, @"expected 1 row, got %lu", (unsigned long)rows.count);
    NSString *label = rowValue(rows[0], 2);
    CHECK([label isKindOfClass:[NSString class]] && [label isEqualToString:@"hello world"],
          @"expected label 'hello world', got %@", label);
}

/* 11. sql */
static void test_sql(void) {
    SKIP_IF_NO_DAEMON();
    NSArray *cols = @[intCol(1, @"id", YES), intCol(2, @"amount", NO)];
    freshTable(@"objc_sql", cols);
    NSError *e = nil;
    int64_t n = [g_client countOfTable:@"objc_sql" error:&e];
    CHECK(n == 0, @"expected 0 rows before SQL INSERT, got %lld", (long long)n);

    /* INSERT via SQL must increase the row count. */
    id body = [g_client sql:@"INSERT INTO objc_sql (id, amount) VALUES (10, 42)" error:&e];
    CHECK(e == nil, @"SQL INSERT failed: %@", e.localizedDescription);
    n = [g_client countOfTable:@"objc_sql" error:&e];
    CHECK(n == 1, @"expected count to increase to 1 after INSERT, got %lld", (long long)n);
    (void)body;
}

/* 12. table_names */
static void test_table_names(void) {
    SKIP_IF_NO_DAEMON();
    NSArray *cols = @[intCol(1, @"id", YES)];
    freshTable(@"objc_tables", cols);
    NSError *e = nil;
    NSArray *names = [g_client tableNames:&e];
    CHECK(e == nil, @"table_names failed: %@", e.localizedDescription);
    BOOL found = NO;
    for (NSString *name in names) {
        if ([name isEqualToString:@"objc_tables"]) {
            found = YES;
            break;
        }
    }
    CHECK(found, @"table list missing objc_tables");
}

/* 13. schema + schema_for */
static void test_schema_for(void) {
    SKIP_IF_NO_DAEMON();
    NSArray *cols = @[intCol(1, @"id", YES), floatCol(2, @"amount")];
    freshTable(@"objc_schema", cols);
    NSError *e = nil;
    NSDictionary *body = [g_client schemaForTable:@"objc_schema" error:&e];
    CHECK(e == nil, @"schema_for failed: %@", e.localizedDescription);
    CHECK(body.count > 0, @"expected non-empty schema body");
}

/* 14. error not_found */
static void test_error_not_found(void) {
    SKIP_IF_NO_DAEMON();
    NSError *e = nil;
    [g_client schemaForTable:@"objc_does_not_exist_xyz" error:&e];
    CHECK(e != nil && e.code == MongrelDBErrorNotFound,
          @"expected MongrelDBErrorNotFound, got %ld (%@)", (long)(e ? e.code : 0),
          e ? e.localizedDescription : @"(nil)");
}

/* 15. idempotency key */
static void test_idempotency_key(void) {
    SKIP_IF_NO_DAEMON();
    NSArray *cols = @[intCol(1, @"id", YES)];
    freshTable(@"objc_idem", cols);
    /* Use a unique idempotency key per run so prior test runs on the same
     * server don't replay stale results. */
    NSString *key = [NSString stringWithFormat:@"idem-key-%lld",
                      (long long)[[NSDate date] timeIntervalSince1970]];
    NSError *e = nil;
    BOOL ok = [g_client putIntoTable:@"objc_idem" cells:@[i64Cell(1, 1)] idempotencyKey:key error:&e];
    CHECK(ok && e == nil, @"put (first) failed: %@", e.localizedDescription);
    int64_t n = [g_client countOfTable:@"objc_idem" error:&e];
    CHECK(n == 1, @"expected 1 row, got %lld", (long long)n);

    /* Second put with a DIFFERENT value but the SAME key replays the original
     * result; the row count stays at 1. */
    [g_client putIntoTable:@"objc_idem" cells:@[i64Cell(1, 2)] idempotencyKey:key error:&e];
    n = [g_client countOfTable:@"objc_idem" error:&e];
    CHECK(n == 1, @"expected 1 row after duplicate idempotent commit, got %lld", (long long)n);
}

/* 16. history retention */
static void test_history_retention(void) {
    SKIP_IF_NO_DAEMON();
    NSError *e = nil;
    uint64_t original = [g_client historyRetentionEpochs:&e];
    CHECK(e == nil, @"historyRetentionEpochs failed: %@", e.localizedDescription);

    NSDictionary *result = [g_client setHistoryRetentionEpochs:1000 error:&e];
    CHECK(e == nil, @"setHistoryRetentionEpochs failed: %@", e.localizedDescription);
    CHECK(result != nil, @"setHistoryRetentionEpochs returned nil");
    CHECK([result[@"history_retention_epochs"] unsignedLongLongValue] == 1000,
          @"setHistoryRetentionEpochs did not return the new window");
    CHECK([result[@"earliest_retained_epoch"] unsignedLongLongValue] <= 1000,
          @"setHistoryRetentionEpochs returned an invalid earliest epoch");

    uint64_t epochs = [g_client historyRetentionEpochs:&e];
    CHECK(e == nil, @"historyRetentionEpochs getter failed: %@", e.localizedDescription);
    CHECK(epochs == 1000, @"historyRetentionEpochs getter did not reflect the set window");

    uint64_t earliest = [g_client earliestRetainedEpoch:&e];
    CHECK(e == nil, @"earliestRetainedEpoch getter failed: %@", e.localizedDescription);
    CHECK(earliest <= 1000, @"earliestRetainedEpoch getter returned an invalid epoch");

    /* Restore the original window. */
    [g_client setHistoryRetentionEpochs:original error:&e];
}

/* Helper: extract an int64 from the first row of a SQL JSON result. */
static int64_t firstIntColumn(id result, NSString *column) {
    if (![result isKindOfClass:[NSArray class]] || [(NSArray *)result count] == 0) {
        return INT64_MIN;
    }
    id row = [(NSArray *)result objectAtIndex:0];
    if (![row isKindOfClass:[NSDictionary class]]) {
        return INT64_MIN;
    }
    id v = [(NSDictionary *)row objectForKey:column];
    if ([v isKindOfClass:[NSNumber class]]) {
        return [(NSNumber *)v longLongValue];
    }
    return INT64_MIN;
}

/* 17. history retention round-trip with AS OF EPOCH */
static void test_history_retention_round_trip(void) {
    SKIP_IF_NO_DAEMON();
    NSArray *cols = @[intCol(1, @"id", YES), intCol(2, @"v", NO)];
    freshTable(@"objc_retention", cols);

    NSError *e = nil;
    uint64_t original = [g_client historyRetentionEpochs:&e];
    CHECK(e == nil, @"historyRetentionEpochs failed: %@", e.localizedDescription);
    [g_client setHistoryRetentionEpochs:1000 error:&e];
    CHECK(e == nil, @"setHistoryRetentionEpochs failed: %@", e.localizedDescription);

    uint64_t epochs = [g_client historyRetentionEpochs:&e];
    CHECK(e == nil, @"historyRetentionEpochs getter failed: %@", e.localizedDescription);
    CHECK(epochs == 1000, @"historyRetentionEpochs getter did not reflect the set window");

    uint64_t earliest = [g_client earliestRetainedEpoch:&e];
    CHECK(e == nil, @"earliestRetainedEpoch getter failed: %@", e.localizedDescription);
    CHECK(earliest <= 1000, @"earliestRetainedEpoch getter returned an invalid epoch");

    /* Insert the first version of the row. */
    BOOL ok = [g_client putIntoTable:@"objc_retention"
                                cells:@[i64Cell(1, 1), i64Cell(2, 100)]
                       idempotencyKey:nil error:&e];
    CHECK(ok && e == nil, @"put failed: %@", e.localizedDescription);
    uint64_t epoch1 = g_client.lastEpoch;
    CHECK(epoch1 > 0, @"lastEpoch was not captured from the commit response");

    /* Update the row; lastEpoch should advance. */
    ok = [g_client putIntoTable:@"objc_retention"
                           cells:@[i64Cell(1, 1), i64Cell(2, 200)]
                  idempotencyKey:nil error:&e];
    CHECK(ok && e == nil, @"update put failed: %@", e.localizedDescription);
    uint64_t epoch2 = g_client.lastEpoch;
    CHECK(epoch2 > epoch1, @"lastEpoch did not advance on second commit");

    /* Current value should be the second version. */
    id current = [g_client sql:@"SELECT v FROM objc_retention WHERE id = 1" error:&e];
    CHECK(e == nil, @"current select failed: %@", e.localizedDescription);
    CHECK(firstIntColumn(current, @"v") == 200, @"current value should be 200");

    /* Time-travel read at the first epoch should see the first version. */
    NSString *asOf = [NSString stringWithFormat:@"SELECT v FROM objc_retention AS OF EPOCH %llu WHERE id = 1",
                      (unsigned long long)epoch1];
    id historical = [g_client sql:asOf error:&e];
    CHECK(e == nil, @"AS OF EPOCH select failed: %@", e.localizedDescription);
    CHECK(firstIntColumn(historical, @"v") == 100, @"historical value should be 100");

    /* Restore the original window. */
    [g_client setHistoryRetentionEpochs:original error:&e];
}

/* 18. explicit AS OF EPOCH time-travel using lastEpoch */
static void test_as_of_epoch_time_travel(void) {
    SKIP_IF_NO_DAEMON();
    NSArray *cols = @[intCol(1, @"id", YES), varcharCol(2, @"label")];
    freshTable(@"objc_time_travel", cols);

    NSError *e = nil;
    uint64_t original = [g_client historyRetentionEpochs:&e];
    CHECK(e == nil, @"historyRetentionEpochs failed: %@", e.localizedDescription);
    [g_client setHistoryRetentionEpochs:1000 error:&e];
    CHECK(e == nil, @"setHistoryRetentionEpochs failed: %@", e.localizedDescription);

    BOOL ok = [g_client putIntoTable:@"objc_time_travel"
                                cells:@[i64Cell(1, 1), strCell(2, @"first")]
                       idempotencyKey:nil error:&e];
    CHECK(ok && e == nil, @"put failed: %@", e.localizedDescription);
    uint64_t epoch1 = g_client.lastEpoch;
    CHECK(epoch1 > 0, @"lastEpoch was not captured");

    ok = [g_client putIntoTable:@"objc_time_travel"
                           cells:@[i64Cell(1, 1), strCell(2, @"second")]
                  idempotencyKey:nil error:&e];
    CHECK(ok && e == nil, @"second put failed: %@", e.localizedDescription);

    NSString *asOf = [NSString stringWithFormat:@"SELECT label FROM objc_time_travel AS OF EPOCH %llu WHERE id = 1",
                      (unsigned long long)epoch1];
    id historical = [g_client sql:asOf error:&e];
    CHECK(e == nil, @"AS OF EPOCH select failed: %@", e.localizedDescription);
    CHECK([historical isKindOfClass:[NSArray class]], @"historical result should be an array");
    CHECK([(NSArray *)historical count] == 1, @"expected one historical row");
    id label = [[(NSArray *)historical objectAtIndex:0] objectForKey:@"label"];
    CHECK([label isKindOfClass:[NSString class]] && [label isEqualToString:@"first"],
          @"historical label should be 'first', got %@", label);

    [g_client setHistoryRetentionEpochs:original error:&e];
}

/* ── Main ──────────────────────────────────────────────────────────────── */

int main(int argc, const char *argv[]) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        setupDaemon();

        RUN(test_health);
        RUN(test_create_table_and_count);
        RUN(test_put_and_count);
        RUN(test_upsert);
        RUN(test_query_by_pk);
        RUN(test_query_range);
        RUN(test_transaction_commit);
        RUN(test_delete_by_pk);
        RUN(test_delete_by_row_id);
        RUN(test_string_values);
        RUN(test_sql);
        RUN(test_table_names);
        RUN(test_schema_for);
        RUN(test_error_not_found);
        RUN(test_idempotency_key);
        RUN(test_history_retention);
        RUN(test_history_retention_round_trip);
        RUN(test_as_of_epoch_time_travel);

        printf("\n%d passed, %d failed, %d skipped\n", g_pass, g_fail, g_skip);
        return g_fail > 0 ? 1 : 0;
    }
}
