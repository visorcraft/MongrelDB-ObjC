/*
 * Example: atomic batch transactions with an idempotent retry in Objective-C.
 *
 * Build (from the repo root, on macOS):
 *
 *   clang -fobjc-arc -Isrc examples/transactions.m src/MongrelDBClient.m \
 *       src/MongrelDBError.m -framework Foundation -o examples/transactions
 *   ./examples/transactions
 *
 * Requires a mongreldb-server daemon running on http://127.0.0.1:8453, or
 * point MONGRELDB_URL at a running daemon.
 *
 * Creates a table, stages three puts in one transaction, and commits them
 * atomically. It then verifies the row count. Finally it stages a fourth put
 * and commits it twice with the SAME idempotency key: the daemon replays the
 * first commit's result so the second commit is a no-op. The table is dropped
 * at the end (even on error).
 */

#import <Foundation/Foundation.h>
#import "MongrelDBClient.h"

#define TABLE_PREFIX @"objc_example_txn_"

/* Build a put-op dict referencing the per-run table name. */
static NSDictionary *putOp(NSString *table, NSArray *row) {
    return @{
        @"put": @{
            @"table": table,
            @"cells": row,
            @"returning": @NO,
        },
    };
}

/* Flatten (value...) into [colId, value, ...] with fixed col ids 1..4. */
static NSArray *flatRow(NSNumber *id, NSString *name, NSNumber *score, NSString *status) {
    return @[ @1, id, @2, name, @3, score, @4, status ];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *url = [NSProcessInfo.processInfo.environment objectForKey:@"MONGRELDB_URL"];
        if (url.length == 0) { url = @"http://127.0.0.1:8453"; }

        long long ts = (long long)[[NSDate date] timeIntervalSince1970];
        NSString *table = [NSString stringWithFormat:@"%@%lld", TABLE_PREFIX, ts];
        NSString *txnKey = [NSString stringWithFormat:@"objc-example-txn-key-%lld", ts];

        NSError *e = nil;
        MongrelDBClient *db = [MongrelDBClient connectWithURL:url error:&e];
        if (!db) {
            fprintf(stderr, "connect failed: %s\n", e.localizedDescription.UTF8String);
            return 1;
        }

        BOOL tableCreated = NO;
        int status = 1;

        /* Forward-declare ARC strong locals so the goto-cleanup pattern below
         * does not jump over their initialization (forbidden under ARC). */
        NSArray *batch1 = nil;
        NSArray *batch2 = nil;

        /* Column schema (enum + default columns). */
        MongrelDBColumn *c1 = [MongrelDBColumn columnWithId:1 name:@"id" type:@"int64"
                                                primaryKey:YES isNullable:NO];
        MongrelDBColumn *c2 = [MongrelDBColumn columnWithId:2 name:@"name" type:@"varchar"
                                                primaryKey:NO isNullable:NO];
        MongrelDBColumn *c3 = [[MongrelDBColumn alloc] init];
        c3.columnId = 3; c3.name = @"score"; c3.type = @"float64";
        c3.primaryKey = NO; c3.isNullable = NO; c3.defaultValueJSON = @0.0;
        MongrelDBColumn *c4 = [[MongrelDBColumn alloc] init];
        c4.columnId = 4; c4.name = @"status"; c4.type = @"enum";
        c4.primaryKey = NO; c4.isNullable = NO;
        c4.enumVariants = @[@"active", @"inactive", @"paused"];
        c4.defaultValue = @"active";

        if (![db health:&e]) {
            fprintf(stderr, "daemon not reachable at %s: %s\n", url.UTF8String,
                    e.localizedDescription.UTF8String);
            return 1;
        }
        printf("Connected to MongrelDB\n");

        int64_t tid = [db createTableWithName:table columns:@[c1, c2, c3, c4] error:&e];
        if (e) { fprintf(stderr, "create_table failed: %s\n", e.localizedDescription.UTF8String); goto cleanup; }
        tableCreated = YES;
        printf("Created table %s (id %lld)\n", table.UTF8String, (long long)tid);

        /* Stage three puts and commit them atomically. */
        batch1 = @[
            putOp(table, flatRow(@(1), @"Alice", @95.5, @"active")),
            putOp(table, flatRow(@(2), @"Bob",   @82.0, @"inactive")),
            putOp(table, flatRow(@(3), @"Carol", @78.3, @"paused")),
        ];
        [db transactionWithOps:batch1 idempotencyKey:nil error:&e];
        if (e) { fprintf(stderr, "commit (3 puts) failed: %s\n", e.localizedDescription.UTF8String); goto cleanup; }
        printf("Committed transaction with 3 puts\n");

        int64_t n = [db countOfTable:table error:&e];
        printf("Total rows after commit: %lld\n", (long long)n);

        /* Idempotent retry: stage a fourth put and commit twice with the same
         * idempotency key. The second commit is replayed as a no-op. */
        batch2 = @[ putOp(table, flatRow(@(4), @"Dave", @60.0, @"active")) ];
        [db transactionWithOps:batch2 idempotencyKey:txnKey error:&e];
        if (e) { fprintf(stderr, "commit (4th put, first) failed: %s\n", e.localizedDescription.UTF8String); goto cleanup; }
        printf("Committed 4th put with idempotency key %s\n", txnKey.UTF8String);

        [db transactionWithOps:batch2 idempotencyKey:txnKey error:&e];
        if (e) { fprintf(stderr, "commit (4th put, retry) failed: %s\n", e.localizedDescription.UTF8String); goto cleanup; }
        printf("Recommitted with same key (idempotent replay)\n");

        n = [db countOfTable:table error:&e];
        printf("Total rows after idempotent retry: %lld\n", (long long)n);

        status = 0;

    cleanup:
        if (tableCreated) {
            e = nil;
            if ([db dropTableWithName:table error:&e]) {
                printf("Dropped table %s\n", table.UTF8String);
            } else {
                fprintf(stderr, "drop_table failed: %s\n", e.localizedDescription.UTF8String);
            }
        }
        return status;
    }
}
