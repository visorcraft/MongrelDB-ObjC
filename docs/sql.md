# SQL

MongrelDB ships a DataFusion-backed SQL engine at `POST /sql`. From Objective-C,
run SQL with `sql:error:`:

```objc
NSError *e = nil;
id body = [db sql:@"SELECT 1" error:&e];
```

This guide covers the SQL surface - DDL, DML, `CREATE TABLE AS SELECT`,
recursive CTEs, and window functions - and when to reach for SQL versus the
native query builder.

---

## How `sql:error:` behaves

`sql:error:` sends `{"sql": "...", "format": "json"}` to `/sql`. It returns the
decoded JSON body on a 2xx response (rows for SELECT, or the status object for
DDL/DML), or nil plus an NSError on failure.

In practice:

- **DDL and DML** (`CREATE TABLE`, `INSERT`, `UPDATE`, `DELETE`) reply with a
  non-JSON status body. `sql:` returns nil - success is the signal (no error).
- **`SELECT`** in most daemon builds streams Arrow IPC bytes rather than JSON,
  but with `format:json` requested the server returns a JSON array of row
  objects keyed by column name when supported.

Errors are mapped to the same error codes as everything else: an HTTP 400 or
5xx is `MongrelDBErrorQuery`; 409 is `MongrelDBErrorConflict`; and so on. See
[errors.md](errors.md).

```objc
[db sql:@"INSERT INTO orders (id, customer, amount) VALUES (99, 'Zoe', 999.0)" error:&e];
if (e && e.code == MongrelDBErrorConflict) {
    NSLog(@"duplicate row: %@", e.localizedDescription);
}
```

## CREATE TABLE

```objc
[db sql:@"CREATE TABLE products ("
         "  id INT64 PRIMARY KEY,"
         "  name VARCHAR,"
         "  price FLOAT64,"
         "  category VARCHAR,"
         "  in_stock BOOLEAN)" error:&e];
```

## INSERT

```objc
[db sql:@"INSERT INTO products (id, name, price, category, in_stock) "
         "VALUES (1, 'Widget', 9.99, 'tools', true)" error:&e];
```

For bulk inserts, the native batch transaction (`transactionWithOps:`) is
usually faster because it stages ops in one round trip without re-parsing SQL.

## UPDATE / DELETE

```objc
[db sql:@"UPDATE products SET price = 14.99 WHERE id = 1" error:&e];
[db sql:@"DELETE FROM products WHERE in_stock = false" error:&e];
```

## SELECT

```objc
id rows = [db sql:@"SELECT id, name FROM products WHERE category = 'tools' ORDER BY price" error:&e];
```

## CREATE TABLE AS SELECT

Materialize a query result into a new table. Great for snapshots, rollups, and
denormalized aggregates.

```objc
[db sql:@"CREATE TABLE archive AS SELECT * FROM orders WHERE amount > 500" error:&e];

/* Roll up sales by customer. */
[db sql:@"CREATE TABLE sales_by_customer AS "
         "SELECT customer, SUM(amount) AS total FROM orders GROUP BY customer" error:&e];
```

## Recursive CTEs

`WITH RECURSIVE` is fully supported. Classic use cases: series generation,
hierarchy/graph traversal.

```objc
[db sql:@"WITH RECURSIVE r(n) AS ("
         "  SELECT 1 UNION ALL SELECT n + 1 FROM r WHERE n < 10"
         ") SELECT n FROM r" error:&e];
```

## Window functions

```objc
[db sql:@"SELECT id, customer, amount, "
         "ROW_NUMBER() OVER (PARTITION BY customer ORDER BY amount DESC) AS rn "
         "FROM orders" error:&e];
```

`RANK()`, `DENSE_RANK()`, `LAG()`, `LEAD()`, `NTILE()`, and the usual
window-frame clauses are available through DataFusion.

## When to use SQL vs. the query builder

| Reach for | When |
|-----------|------|
| **`queryTable:`** | Point lookups, range scans, bitmap filters, and full-text that map to a native index. Sub-millisecond, no parser overhead, and rows decode into typed values directly. |
| **SQL** | DDL, multi-statement setup, joins, recursive CTEs, window functions, and arbitrary aggregates. Also the natural choice for admin scripts. |

## Next steps

- [queries.md](queries.md) - every native index condition in detail
- [transactions.md](transactions.md) - bulk inserts via batch transactions
- [errors.md](errors.md) - handling SQL execution errors
