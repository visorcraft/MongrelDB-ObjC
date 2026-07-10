# Authentication & Authorization

A `mongreldb-server` daemon runs in one of three modes:

1. **Open** (default) - no auth required.
2. **Bearer token** (`--auth-token <TOKEN>`) - every request must carry an
   `Authorization: Bearer <TOKEN>` header.
3. **HTTP Basic** (`--auth-users`) - every request must carry an
   `Authorization: Basic <base64(user:pass)>` header.

The Objective-C client supports all three through the `connect*` class methods.
This guide shows each mode and how to manage users and roles via SQL when the
server is in Basic mode.

---

## Bearer token mode

Start the daemon with a token:

```sh
mongreldb-server --auth-token s3cret-token
```

Connect with `connectWithURL:token:error:`. The token is sent as
`Authorization: Bearer ...` on every request.

```objc
NSError *e = nil;
MongrelDBClient *db = [MongrelDBClient connectWithURL:@"http://127.0.0.1:8453"
                                                token:@"s3cret-token"
                                               error:&e];

if ([db health:&e] && e && e.code == MongrelDBErrorAuth) {
    NSLog(@"bad or missing token");
    return 1;
}
```

A missing or wrong token surfaces as `MongrelDBErrorAuth` (HTTP 401/403).

### Where the token comes from

Hard-coding secrets in source is bad practice. Read it from the environment:

```objc
NSString *token = [NSProcessInfo.processInfo.environment objectForKey:@"MONGRELDB_TOKEN"];
if (token.length == 0) {
    NSLog(@"MONGRELDB_TOKEN not set");
    return 1;
}
MongrelDBClient *db = [MongrelDBClient connectWithURL:nil token:token error:&e];
```

## Basic auth mode

Connect with `connectWithURL:username:password:error:`:

```objc
MongrelDBClient *db = [MongrelDBClient connectWithURL:@"http://127.0.0.1:8453"
                                             username:@"admin"
                                             password:@"s3cret"
                                                error:&e];
```

The client base64-encodes `username:password` and sets
`Authorization: Basic ...` on every request.

## Token takes precedence

A token takes precedence over basic auth. The two constructors are separate, so
in practice you pick one, but the rule holds if you ever layer them.

## Timeouts

`setTimeout:` sets the per-request timeout in seconds (default 30). This applies
to both the connect and transfer phases.

```objc
MongrelDBClient *db = [MongrelDBClient connectWithURL:url token:token error:&e];
[db setTimeout:60]; /* 60 seconds */
```

## User and role management via SQL

When the daemon is in Basic auth mode, users and roles live in the catalog and
are managed with SQL. Run these statements through `sql:error:`.

### Create a user

```objc
[db sql:@"CREATE USER alice WITH PASSWORD 'hunter2'" error:&e];
```

### Alter a user

```objc
[db sql:@"ALTER USER alice WITH PASSWORD 'new-password'" error:&e];
[db sql:@"ALTER USER alice ADMIN" error:&e];
```

`ALTER USER ... ADMIN` is how you promote a user to full administrative
privileges (table creation/drop, compaction, user management). Use it
sparingly.

### Drop a user

```objc
[db sql:@"DROP USER alice" error:&e];
```

### Roles and grants

```objc
[db sql:@"CREATE ROLE analyst" error:&e];
[db sql:@"GRANT SELECT ON orders TO analyst" error:&e];
[db sql:@"GRANT analyst TO alice" error:&e];
[db sql:@"REVOKE SELECT ON orders FROM analyst" error:&e];
[db sql:@"DROP ROLE analyst" error:&e];
```

## Common pitfalls

**Auth errors look like other errors without the code.** A 401/403 maps to
`MongrelDBErrorAuth`; a 404 maps to `MongrelDBErrorNotFound`. Always switch on
the error code rather than string-matching the description.

**Forgetting to set auth in production.** A client built with
`connectWithURL:nil` and no auth sends no credentials. Against an auth-enabled
daemon, every call fails with `MongrelDBErrorAuth`. Centralize client
construction so the auth constructor is never accidentally dropped.

**Token in version control.** Put secrets in the environment, a secret
manager, or a file outside the repo. Never commit a real token.

## Next steps

- [errors.md](errors.md) - `MongrelDBErrorAuth` and the rest of the error codes
- [quickstart.md](quickstart.md) - the full end-to-end walkthrough
