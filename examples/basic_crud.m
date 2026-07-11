/*
 * Example: basic CRUD operations with the MongrelDB Objective-C client.
 *
 * Build (from the repo root, on macOS):
 *
 *   clang -fobjc-arc -Isrc examples/basic_crud.m src/MongrelDBClient.m \
 *       src/MongrelDBError.m -framework Foundation -o examples/basic_crud
 *   ./examples/basic_crud
 *
 * Requires a mongreldb-server daemon running on http://127.0.0.1:8453, or
 * point MONGRELDB_URL at a running daemon.
 *
 * Creates a table, inserts three rows, counts them, queries all rows, upserts
 * (updates) one row by primary key, deletes one row, then drops the table.
 * Progress is printed at every step.
 *
 * The "status" column is an enum ("active" | "inactive" | "paused") with a
 * default of "active"; the "score" column has a numeric default of "0.0".
 * These are emitted as "enum_variants" and "default_value" keys in the
 * /kit/create_table wire JSON.
 */

#import <Foundation/Foundation.h>
#import "MongrelDBClient.h"

#define TABLE_PREFIX @"objc_example_crud_"

/* Print every cell of a query result. */
static void printResult(NSArray<NSDictionary *> *rows) {
    for (NSDictionary *row in rows) {
        printf("  { ");
        BOOL first = YES;
        for (NSNumber *colId in row) {
            if (!first) { printf(", "); }
            first = NO;
            printf("col%s=", [[colId stringValue] UTF8String]);
            id v = row[colId];
            if ([v isKindOfClass:[NSString class]]) {
                printf("%s", [v UTF8String]);
            } else if ([v isKindOfClass:[NSNumber class]]) {
                printf("%s", [[v stringValue] UTF8String]);
            } else if (v == NSNull.null) {
                printf("null");
            } else {
                printf("%s", [[v description] UTF8String]);
            }
        }
        printf(" }\n");
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *url = [NSProcessInfo.processInfo.environment objectForKey:@"MONGRELDB_URL"];
        if (url.length == 0) { url = @"http://127.0.0.1:8453"; }

        /* Per-run unique suffix (unix time) keeps every invocation isolated
         * on a shared daemon. */
        NSString *table = [NSString stringWithFormat:@"%@%lld", TABLE_PREFIX,
                            (long long)[[NSDate date] timeIntervalSince1970]];

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
        NSArray *mkRow = nil, *mkRow2 = nil, *mkRow3 = nil;
        NSArray *rows = nil;
        NSArray *up = nil, *upd = nil;

        /* Column schema:
         *   col 1 = id (int64, primary key)
         *   col 2 = name (varchar)
         *   col 3 = score (float64, default "0.0")
         *   col 4 = status (varchar, enum ["active","inactive","paused"], default "active")
         */
        NSArray *statusVariants = @[@"active", @"inactive", @"paused"];
        MongrelDBColumn *c1 = [MongrelDBColumn columnWithId:1 name:@"id" type:@"int64"
                                                primaryKey:YES nullable:NO];
        MongrelDBColumn *c2 = [MongrelDBColumn columnWithId:2 name:@"name" type:@"varchar"
                                                primaryKey:NO nullable:NO];
        MongrelDBColumn *c3 = [[MongrelDBColumn alloc] init];
        c3.columnId = 3; c3.name = @"score"; c3.type = @"float64";
        c3.primaryKey = NO; c3.nullable = NO; c3.defaultValue = @"0.0";
        MongrelDBColumn *c4 = [[MongrelDBColumn alloc] init];
        c4.columnId = 4; c4.name = @"status"; c4.type = @"varchar";
        c4.primaryKey = NO; c4.nullable = NO;
        c4.enumVariants = statusVariants; c4.defaultValue = @"active";

        /* 1. Health check. */
        if (![db health:&e]) {
            fprintf(stderr, "daemon not reachable at %s: %s\n", url.UTF8String,
                    e.localizedDescription.UTF8String);
            return 1;
        }
        printf("Connected to MongrelDB\n");

        /* 2. Create the table. */
        int64_t tid = [db createTableWithName:table columns:@[c1, c2, c3, c4] error:&e];
        if (e) {
            fprintf(stderr, "create_table failed: %s\n", e.localizedDescription.UTF8String);
            goto cleanup;
        }
        tableCreated = YES;
        printf("Created table %s (id %lld)\n", table.UTF8String, (long long)tid);

        /* 3. Insert three rows. */
        NSArray *row(NSArray *cells); /* forward */
        mkRow = @[
            [MongrelDBInputCell cellWithColumnId:1 value:@(1)],
            [MongrelDBInputCell cellWithColumnId:2 value:@"Alice"],
            [MongrelDBInputCell cellWithColumnId:3 value:@(95.5)],
            [MongrelDBInputCell cellWithColumnId:4 value:@"active"],
        ];
        mkRow2 = @[
            [MongrelDBInputCell cellWithColumnId:1 value:@(2)],
            [MongrelDBInputCell cellWithColumnId:2 value:@"Bob"],
            [MongrelDBInputCell cellWithColumnId:3 value:@(82.0)],
            [MongrelDBInputCell cellWithColumnId:4 value:@"inactive"],
        ];
        mkRow3 = @[
            [MongrelDBInputCell cellWithColumnId:1 value:@(3)],
            [MongrelDBInputCell cellWithColumnId:2 value:@"Carol"],
            [MongrelDBInputCell cellWithColumnId:3 value:@(78.3)],
            [MongrelDBInputCell cellWithColumnId:4 value:@"paused"],
        ];
        (void)mkRow; (void)row;
        [db putIntoTable:table cells:mkRow idempotencyKey:nil error:&e];
        if (e) { fprintf(stderr, "put failed: %s\n", e.localizedDescription.UTF8String); goto cleanup; }
        [db putIntoTable:table cells:mkRow2 idempotencyKey:nil error:&e];
        if (e) { fprintf(stderr, "put failed: %s\n", e.localizedDescription.UTF8String); goto cleanup; }
        [db putIntoTable:table cells:mkRow3 idempotencyKey:nil error:&e];
        if (e) { fprintf(stderr, "put failed: %s\n", e.localizedDescription.UTF8String); goto cleanup; }
        printf("Inserted 3 rows\n");

        /* 4. Count. */
        int64_t n = [db countOfTable:table error:&e];
        if (e) { fprintf(stderr, "count failed: %s\n", e.localizedDescription.UTF8String); goto cleanup; }
        printf("Total rows: %lld\n", (long long)n);

        /* 5. Query all rows. */
        BOOL trunc = NO;
        rows = [db queryTable:table conditions:nil projection:nil
                                 limit:0 truncated:&trunc error:&e];
        if (e) { fprintf(stderr, "query failed: %s\n", e.localizedDescription.UTF8String); goto cleanup; }
        printf("Query returned %lu rows:\n", (unsigned long)rows.count);
        printResult(rows);

        /* 6. Upsert (update) Alice's score and mark her paused. */
        up = @[
            [MongrelDBInputCell cellWithColumnId:1 value:@(1)],
            [MongrelDBInputCell cellWithColumnId:2 value:@"Alice"],
            [MongrelDBInputCell cellWithColumnId:3 value:@(100.0)],
            [MongrelDBInputCell cellWithColumnId:4 value:@"paused"],
        ];
        upd = @[
            [MongrelDBInputCell cellWithColumnId:2 value:@"Alice"],
            [MongrelDBInputCell cellWithColumnId:3 value:@(100.0)],
            [MongrelDBInputCell cellWithColumnId:4 value:@"paused"],
        ];
        [db upsertIntoTable:table cells:up updateCells:upd idempotencyKey:nil error:&e];
        if (e) { fprintf(stderr, "upsert failed: %s\n", e.localizedDescription.UTF8String); goto cleanup; }
        printf("Upserted Alice's score to 100.0\n");
        n = [db countOfTable:table error:&e];
        printf("Total rows after upsert: %lld\n", (long long)n);

        /* 7. Delete Carol (primary key 3). */
        [db deleteFromTable:table primaryKeyValue:@(3) error:&e];
        if (e) { fprintf(stderr, "delete_by_pk failed: %s\n", e.localizedDescription.UTF8String); goto cleanup; }
        n = [db countOfTable:table error:&e];
        printf("Deleted Carol; remaining rows: %lld\n", (long long)n);

        status = 0;

    cleanup:
        /* Guaranteed cleanup: drop the table if it was created. */
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
