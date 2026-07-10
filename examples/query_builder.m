/*
 * Example: native query builder (range + primary-key lookups) in Objective-C.
 *
 * Build (from the repo root, on macOS):
 *
 *   clang -fobjc-arc -Isrc examples/query_builder.m src/MongrelDBClient.m \
 *       src/MongrelDBError.m -framework Foundation -o examples/query_builder
 *   ./examples/query_builder
 *
 * Requires a mongreldb-server daemon running on http://127.0.0.1:8453, or
 * point MONGRELDB_URL at a running daemon.
 *
 * Creates a table, loads five rows with varying scores, then runs two
 * native queries: a range scan over score in [60, 90], and an exact
 * primary-key lookup for id == 4. Results are printed, then the table is
 * dropped (even on error).
 */

#import <Foundation/Foundation.h>
#import "MongrelDBClient.h"

#define TABLE_PREFIX @"objc_example_query_"

static void printResult(NSString *label, NSArray<NSDictionary *> *rows) {
    printf("  %s: %lu rows\n", label.UTF8String, (unsigned long)rows.count);
    for (NSDictionary *row in rows) {
        printf("    { ");
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

        /* Column schema:
         *   col 1 = id (int64, primary key)
         *   col 2 = name (varchar)
         *   col 3 = score (float64)
         */
        NSArray *cols = @[
            [MongrelDBColumn columnWithId:1 name:@"id" type:@"int64" primaryKey:YES nullable:NO],
            [MongrelDBColumn columnWithId:2 name:@"name" type:@"varchar" primaryKey:NO nullable:NO],
            [MongrelDBColumn columnWithId:3 name:@"score" type:@"float64" primaryKey:NO nullable:NO],
        ];

        if (![db health:&e]) {
            fprintf(stderr, "daemon not reachable at %s: %s\n", url.UTF8String,
                    e.localizedDescription.UTF8String);
            return 1;
        }
        printf("Connected to MongrelDB\n");

        int64_t tid = [db createTableWithName:table columns:cols error:&e];
        if (e) { fprintf(stderr, "create_table failed: %s\n", e.localizedDescription.UTF8String); goto cleanup; }
        tableCreated = YES;
        printf("Created table %s (id %lld)\n", table.UTF8String, (long long)tid);

        /* Load five rows with varying scores. */
        NSArray *mk(NSString *name, double score); (void)mk;
        NSArray *rows_to_insert = @[
            @[ @1, @"Alice", @40.0 ],
            @[ @2, @"Bob",   @65.0 ],
            @[ @3, @"Carol", @82.0 ],
            @[ @4, @"Dave",  @91.0 ],
            @[ @5, @"Eve",   @12.5 ],
        ];
        for (NSArray *r in rows_to_insert) {
            NSArray *cells = @[
                [MongrelDBInputCell cellWithColumnId:1 value:r[0]],
                [MongrelDBInputCell cellWithColumnId:2 value:r[1]],
                [MongrelDBInputCell cellWithColumnId:3 value:r[2]],
            ];
            [db putIntoTable:table cells:cells idempotencyKey:nil error:&e];
            if (e) { fprintf(stderr, "put failed: %s\n", e.localizedDescription.UTF8String); goto cleanup; }
        }
        printf("Inserted 5 rows\n");

        /* Range query: 60 <= score <= 90 (both inclusive). */
        MongrelDBCondition *rangeCond = [[MongrelDBCondition alloc] init];
        rangeCond.kind = MongrelDBConditionRange;
        rangeCond.columnId = 3;
        rangeCond.lo = 60.0; rangeCond.loSet = YES;
        rangeCond.hi = 90.0; rangeCond.hiSet = YES;
        NSArray *res = [db queryTable:table conditions:@[rangeCond] projection:nil
                                 limit:0 truncated:nil error:&e];
        if (e) { fprintf(stderr, "range query failed: %s\n", e.localizedDescription.UTF8String); goto cleanup; }
        printResult(@"range [60, 90] on score", res);

        /* Primary-key lookup: id == 4 (Dave). */
        MongrelDBCondition *pkCond = [[MongrelDBCondition alloc] init];
        pkCond.kind = MongrelDBConditionPK;
        pkCond.value = @(4);
        res = [db queryTable:table conditions:@[pkCond] projection:nil
                       limit:0 truncated:nil error:&e];
        if (e) { fprintf(stderr, "pk query failed: %s\n", e.localizedDescription.UTF8String); goto cleanup; }
        printResult(@"pk == 4", res);

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
