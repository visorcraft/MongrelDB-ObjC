# Transactions

MongrelDB commits every write through a single atomic transaction endpoint
(`POST /kit/txn`). This guide covers the two ways to use it - a one-shot
single op, and a staged batch - plus idempotency keys for safe retries and
constraint-violation handling.

The engine enforces `UNIQUE`, foreign-key, check, and trigger constraints at
**commit time**. A violation aborts the entire batch: no op in the batch
becomes visible.

---

## Single puts vs. batch transactions

### Single op: `putIntoTable:cells:`

`putIntoTable:` is a convenience wrapper that sends a one-op transaction. Use
it when a write is independent and you do not need atomicity across multiple
rows.

```objc
NSArray *cells = @[
    [MongrelDBInputCell cellWithColumnId:1 value:@1],
    [MongrelDBInputCell cellWithColumnId:2 value:@"Alice"],
    [MongrelDBInputCell cellWithColumnId:3 value:@99.5],
];
NSError *e = nil;
BOOL ok = [db putIntoTable:@"orders" cells:cells idempotencyKey:nil error:&e];
if (!ok) {
    NSLog(@"put failed: %@", e.localizedDescription);
}
```

`upsertIntoTable:`, `deleteFromTable:rowId:`, and
`deleteFromTable:primaryKeyValue:` are the same shape: single-op transactions.

### Batch: `transactionWithOps:`

When several writes must succeed or fail together, stage them in an ops array
and commit once. All ops go to the server in a single HTTP request and commit
atomically.

```objc
NSArray *ops = @[
    @{@"put": @{@"table": @"orders", @"cells": @[@1, @10, @2, @"Dave"], @"returning": @NO}},
    @{@"put": @{@"table": @"orders", @"cells": @[@1, @11, @2, @"Eve"], @"returning": @NO}},
    @{@"delete_by_pk": @{@"table": @"orders", @"pk": @2}},
];
NSError *e = nil;
NSArray *results = [db transactionWithOps:ops idempotencyKey:nil error:&e];
```

An `upsert` op takes an additional `update_cells` array applied on a
primary-key conflict. Omitting it means "do nothing on conflict".

## Idempotency keys for safe retries

Networks drop requests and daemons crash after committing but before replying.
An idempotency key makes a commit safe to retry: the daemon remembers the key
and replays the **original** result on a duplicate commit, even across restarts.

Pass the key as the last argument to `transactionWithOps:` (or
`putIntoTable:` / `upsertIntoTable:`):

```objc
NSArray *ops = @[
    @{@"put": @{@"table": @"charges", @"cells": @[@1, orderId, @2, @199.0], @"returning": @NO}},
];
/* On a retry with the same key the daemon returns the first commit's result
 * instead of inserting a second row. */
[db transactionWithOps:ops idempotencyKey:@"charge-order-123" error:&e];
```

Rules for keys:

- Any non-empty string works. Prefer content-derived, globally-unique values
  (e.g. `@"charge:" + orderId`).
- nil (or the empty string) disables idempotency - a retry will commit again.
- The key scopes the **entire batch**, not individual ops. Reuse the exact
  same ops and key together when retrying.

## Handling constraint violations

Constraint violations arrive as HTTP 409, mapped to `MongrelDBErrorConflict`.
The NSError's `localizedDescription` carries the daemon's structured message:

```objc
NSError *e = nil;
[db transactionWithOps:ops idempotencyKey:nil error:&e];
if (e) {
    if (e.code == MongrelDBErrorConflict) {
        NSLog(@"constraint violated: %@", e.localizedDescription);
        /* The engine already rolled back the whole batch. Nothing to undo. */
    } else if (e.code == MongrelDBErrorAuth) {
        NSLog(@"not authorized: %@", e.localizedDescription);
    } else {
        NSLog(@"commit failed: %@", e.localizedDescription);
    }
}
```

Structured codes you will commonly see in the message:

| code | Meaning |
|------|---------|
| `UNIQUE_VIOLATION` | A unique/PK constraint rejected the commit |
| `FK_VIOLATION` | A foreign-key reference was missing |
| `CHECK_VIOLATION` | A check constraint or trigger rejected the commit |
| `NOT_FOUND` | A named resource (table, schema) does not exist |

## Rollback

There are two notions of "rollback":

1. **Server-side.** When `transactionWithOps:` fails with
   `MongrelDBErrorConflict`, the engine has already discarded the entire
   batch. Nothing was written; there is no server rollback to perform.
2. **Client-side.** Because ops are staged in your own array, discarding them
   is just a matter of not calling `transactionWithOps:`. There is no
   transaction handle to roll back - the batch only exists once you send it.

```objc
if (!businessRuleOk()) {
    /* Don't commit. The daemon has seen nothing. */
    return;
}
[db transactionWithOps:ops idempotencyKey:nil error:&e];
```

## Summary

| Goal | Use |
|------|-----|
| One independent write | `putIntoTable:` / `upsertIntoTable:` / `deleteFromTable:` |
| Several writes that must commit together | `transactionWithOps:` with an ops array |
| Retry safely after a network blip | `transactionWithOps:` with a stable idempotency key |
| Distinguish constraint classes | Check `MongrelDBErrorConflict` and read the message |
| Abort before sending | Don't call `transactionWithOps:` - the batch is local |

See [errors.md](errors.md) for the full error code set and [queries.md](queries.md)
for read patterns.
