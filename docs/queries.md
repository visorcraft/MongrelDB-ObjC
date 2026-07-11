# Queries

The `queryTable:conditions:projection:limit:truncated:error:` method pushes
conditions down to MongrelDB's native indexes for sub-millisecond lookups -
bitmap, learned-range, FM-index full text, and more. Each condition type maps
to one specialized index; conditions are AND-ed together.

```objc
MongrelDBCondition *cond = [[MongrelDBCondition alloc] init];
cond.kind = MongrelDBConditionRange;
cond.columnId = 3;
cond.lo = 100; cond.loSet = YES;
cond.hi = 500; cond.hiSet = YES;
BOOL trunc = NO;
NSArray *rows = [db queryTable:@"orders" conditions:@[cond]
                    projection:@[@1, @2] limit:100 truncated:&trunc error:&e];
```

This guide covers every condition type, projection, limits and truncation, and
combining conditions.

---

## The basics

Every query call takes the table, an array of conditions, a projection, a
limit, and a truncated out-pointer:

| Argument | Purpose |
|----------|---------|
| `conditions` (or nil) | An array of native conditions. All are AND-ed. |
| `projection` (or nil) | Return only these column ids (nil means all columns). |
| `limit` (or 0) | Cap the number of rows. |
| `truncated` (or NULL) | Receives YES when the result hit the limit. |

The request body the client builds matches the daemon's `/kit/query` shape:

```json
{
  "table": "orders",
  "conditions": [{"range": {"column_id": 3, "lo": 100, "hi": 500}}],
  "projection": [1, 2],
  "limit": 100
}
```

Each returned row is an NSDictionary mapping column-id (NSNumber) -> value.
Values come back as NSNumber (int64/float64/bool), NSString, or NSNull.

## Condition types

Each `MongrelDBCondition` has a `kind` and a set of fields. Column references
use the numeric **column id**, never the column name.

### `MongrelDBConditionPK` - exact primary-key match

The fastest lookup. Supply the primary-key value in the `value` field (NSNumber
for integer PKs, NSString for string PKs).

```objc
MongrelDBCondition *cond = [[MongrelDBCondition alloc] init];
cond.kind = MongrelDBConditionPK;
cond.value = @42;
NSArray *rows = [db queryTable:@"orders" conditions:@[cond]
                    projection:nil limit:0 truncated:nil error:&e];
```

### `MongrelDBConditionRange` - integer range (learned-range index)

Inclusive bounds on an integer column. Leave `loSet` / `hiSet` at NO for an open end.

```objc
MongrelDBCondition *cond = [[MongrelDBCondition alloc] init];
cond.kind = MongrelDBConditionRange;
cond.columnId = 3;
cond.lo = 100; cond.loSet = YES;
cond.hi = 500; cond.hiSet = YES;
```

### `MongrelDBConditionRangeF64` - floating-point range

For `float64` columns. Set `loInclusive` / `hiInclusive` explicitly (default NO).

```objc
MongrelDBCondition *cond = [[MongrelDBCondition alloc] init];
cond.kind = MongrelDBConditionRangeF64;
cond.columnId = 3;
cond.loF64 = 10.5; cond.loSet = YES; cond.loInclusive = YES;
cond.hiF64 = 99.99; cond.hiSet = YES; cond.hiInclusive = NO;
```

### `MongrelDBConditionBitmapEq` - equality on a bitmap-indexed column

Best for low-cardinality columns (status, category, booleans).

```objc
MongrelDBCondition *cond = [[MongrelDBCondition alloc] init];
cond.kind = MongrelDBConditionBitmapEq;
cond.columnId = 2;
cond.value = @"Alice";
```

### `MongrelDBConditionIsNull` / `MongrelDBConditionIsNotNull` - null checks

```objc
MongrelDBCondition *isNull = [[MongrelDBCondition alloc] init];
isNull.kind = MongrelDBConditionIsNull;
isNull.columnId = 3;

MongrelDBCondition *notNull = [[MongrelDBCondition alloc] init];
notNull.kind = MongrelDBConditionIsNotNull;
notNull.columnId = 3;
```

### `MongrelDBConditionFmContains` - full-text substring search (FM-index)

Substring match within a column. The `value` becomes the on-wire `pattern`.

```objc
MongrelDBCondition *cond = [[MongrelDBCondition alloc] init];
cond.kind = MongrelDBConditionFmContains;
cond.columnId = 2;
cond.value = @"database performance";
NSArray *rows = [db queryTable:@"documents" conditions:@[cond]
                    projection:nil limit:10 truncated:nil error:&e];
```

## Projection (column selection)

Pass a `projection` array to restrict the columns in each returned row. Pass
nil for all columns. Projecting to only the columns you need cuts bandwidth
and decode cost.

```objc
NSArray *rows = [db queryTable:@"orders" conditions:conds
                    projection:@[@1, @2] limit:100 truncated:nil error:&e];
```

Returned cells are decoded into NSNumber / NSString / NSNull values. Check the
class to read the right type:

```objc
for (NSDictionary *row in rows) {
    for (NSNumber *colId in row) {
        id v = row[colId];
        if ([v isKindOfClass:[NSNumber class]]) {
            NSLog(@"col %@ = %@", colId, v);
        } else if ([v isKindOfClass:[NSString class]]) {
            NSLog(@"col %@ = %@", colId, v);
        } else if (v == NSNull.null) {
            NSLog(@"col %@ = null", colId);
        }
    }
}
```

## Limit and the truncated flag

A non-zero `limit` caps the result. When the server has more matches than the
limit allows, it returns the first `limit` and sets `truncated` to YES.

```objc
BOOL trunc = NO;
NSArray *rows = [db queryTable:@"orders" conditions:@[cond]
                    projection:nil limit:100 truncated:&trunc error:&e];
if (trunc) {
    /* 100 rows came back but more exist on the server. */
}
```

## Multiple AND conditions

Pass an array of conditions. Every condition must match; the server intersects
the index results.

```objc
MongrelDBCondition *bitmap = [[MongrelDBCondition alloc] init];
bitmap.kind = MongrelDBConditionBitmapEq;
bitmap.columnId = 2;
bitmap.value = @"Alice";

MongrelDBCondition *range = [[MongrelDBCondition alloc] init];
range.kind = MongrelDBConditionRange;
range.columnId = 3;
range.lo = 100; range.loSet = YES;
range.hi = 500; range.hiSet = YES;

NSArray *rows = [db queryTable:@"orders" conditions:@[bitmap, range]
                    projection:@[@1, @3] limit:50 truncated:nil error:&e];
```

For arbitrary predicates, joins, and aggregations that the native indexes do
not cover, use SQL instead - see [sql.md](sql.md).
