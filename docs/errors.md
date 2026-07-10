# Error handling

Every method that can fail takes an `NSError **` out-parameter. On failure the
error's domain is `MongrelDBErrorDomain` and its code is one of the
`MongrelDBErrorCode` constants. The `localizedDescription` carries the daemon's
message when one was supplied.

---

## The error model

The client uses two complementary mechanisms:

1. **Error codes** - `MongrelDBErrorAuth`, `MongrelDBErrorNotFound`,
   `MongrelDBErrorConflict`, `MongrelDBErrorQuery`, `MongrelDBErrorNetwork`,
   `MongrelDBErrorJSON`, `MongrelDBErrorInvalidArg`. Switch on these to branch
   on the *category* of failure.
2. **`localizedDescription`** - a human-readable message for the failure,
   including the daemon's structured error code when the server supplied one.

## Error code reference

| Code | Value | Meaning | Typical cause |
|------|-------|---------|---------------|
| (success) | 0 | success | method returned YES / a value with nil error |
| `MongrelDBErrorAuth` | -1 | HTTP 401 or 403 | Missing/bad credentials against an auth-enabled daemon |
| `MongrelDBErrorNotFound` | -2 | HTTP 404 | Missing table, missing schema, dropped resource |
| `MongrelDBErrorConflict` | -3 | HTTP 409 | Unique, foreign-key, check, or trigger violation at commit |
| `MongrelDBErrorQuery` | -4 | HTTP 400 or 5xx | Malformed request, server-side failure, everything else |
| `MongrelDBErrorNetwork` | -5 | transport error | Connection refused, timeout, DNS failure |
| `MongrelDBErrorJSON` | -6 | client-side | Malformed JSON response from the server |
| `MongrelDBErrorInvalidArg` | -8 | client-side | nil or otherwise invalid argument |

## The daemon's error envelope

When the daemon rejects a request, it returns a JSON envelope decoded into the
NSError's localizedDescription:

```json
{
  "status": "aborted",
  "error": {
    "code": "UNIQUE_VIOLATION",
    "message": "duplicate key in column 1",
    "op_index": 0
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

## HTTP status -> code mapping

| HTTP status | Code | Notes |
|-------------|------|-------|
| 401, 403 | `MongrelDBErrorAuth` | Bad/missing credentials |
| 404 | `MongrelDBErrorNotFound` | Resource not found |
| 409 | `MongrelDBErrorConflict` | Constraint violation at commit |
| 400 | `MongrelDBErrorQuery` | Malformed request / bad query |
| 5xx | `MongrelDBErrorQuery` | Daemon-side failure |
| other non-2xx | `MongrelDBErrorQuery` | Catch-all |
| 2xx | (success) | No error |

## Discriminating errors

Switch on the error code:

```objc
NSDictionary *body = [db schemaForTable:@"missing_table" error:&e];
if (e) {
    switch (e.code) {
        case MongrelDBErrorNotFound:
            NSLog(@"table does not exist: %@", e.localizedDescription);
            break;
        case MongrelDBErrorConflict:
            NSLog(@"unexpected conflict on a read: %@", e.localizedDescription);
            break;
        case MongrelDBErrorAuth:
            NSLog(@"bad credentials: %@", e.localizedDescription);
            break;
        case MongrelDBErrorQuery:
            NSLog(@"server error: %@", e.localizedDescription);
            break;
        case MongrelDBErrorNetwork:
            NSLog(@"can't reach daemon: %@", e.localizedDescription);
            break;
        default:
            NSLog(@"error: %@", e.localizedDescription);
            break;
    }
    e = nil; /* reset before the next call */
}
```

## Recovery patterns

### Auth failure - do not retry blindly

A retry will not fix bad credentials. Surface the error to the caller or
operator.

### Not found - fall back, do not crash

For lookups by primary key, a 404 may be a normal "absent" result (when the
table itself is missing). Treat it accordingly.

### Constraint conflict - the engine already rolled back

```objc
if (e.code == MongrelDBErrorConflict) {
    NSLog(@"constraint violated: %@", e.localizedDescription);
    /* The engine already discarded the whole batch. Nothing to undo. */
}
```

### Transient failure - retry with an idempotency key

`MongrelDBErrorNetwork` and `MongrelDBErrorQuery` (for 5xx) cover transport and
transient server failures. With an idempotency key, retrying a transaction is
safe (see [transactions.md](transactions.md)).

## Next steps

- [transactions.md](transactions.md) - constraint handling and retries in context
- [auth.md](auth.md) - credential management
