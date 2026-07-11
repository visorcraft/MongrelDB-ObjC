# Contributing to MongrelDB ObjC

Thanks for taking the time to help the MongrelDB Objective-C client. This
document describes how to propose a change, what we expect from a pull request,
and the coding standards that apply to the codebase.

If anything here is unclear or out of date, open an issue or a PR.

## Code of conduct

Be kind, be specific, assume good faith. Disagree about the technical details,
not the person. Public reviews stay focused on the diff.

## How to propose a change

The MongrelDB ObjC client uses a standard **fork -> branch -> pull request**
workflow on GitHub.

1. **Fork** [`visorcraft/MongrelDB-ObjC`](https://github.com/visorcraft/MongrelDB-ObjC)
   to your GitHub account.
2. **Clone** your fork and add the upstream remote:

   ```sh
   git clone git@github.com:<you>/MongrelDB-ObjC.git
   cd MongrelDB-ObjC
   git remote add upstream https://github.com/visorcraft/MongrelDB-ObjC.git
   ```

3. **Branch** from `master`. Pick a descriptive, kebab-case branch name:
   `fix-query-decode`, `feature/vector-search`, `docs/auth-guide`.
4. **Make focused commits.** One logical change per commit. Run the preflight
   (see below) before pushing.
5. **Open a pull request** against `master` on `visorcraft/MongrelDB-ObjC`.

## Before you push: preflight

Run the full CI preflight locally:

```sh
cmake -B build -DCMAKE_BUILD_TYPE=Debug -DCMAKE_OBJC_FLAGS="-Wall -Wextra -Werror"
cmake --build build
ctest --test-dir build --output-on-failure
```

The build must be warning-clean under `-Wall -Wextra`. If a check fails, fix the
root cause - don't silence warnings or skip the test.

To run the live integration suite (requires a running `mongreldb-server`):

```sh
MONGRELDB_URL=http://127.0.0.1:8453 ctest --test-dir build --output-on-failure
```

Live tests self-skip when no server is reachable.

## What we look for in a review

- The change does one thing and does it well.
- Behavior changes ship with tests. New client behavior: a unit test alongside
  the code. Wire-format changes: cover the exact outgoing JSON keys.
  Daemon-dependent coverage: a live test that skips cleanly when no server is
  available.
- The change keeps this repo a thin client over `mongreldb-server`. Don't
  re-implement storage, indexing, WAL, or SQL planning logic here.
- Documentation is updated alongside the code (`docs/`, `README.md`) if the
  change affects users.
- Commits have clear messages (see below).

## Coding standards

### Objective-C

- **Version.** Objective-C 2.0 with ARC (Automatic Reference Counting).
- **Warnings.** `-Wall -Wextra` must be clean. Treat warnings as errors locally
  (`-Werror`).
- **Dependencies.** Apple Foundation (NSURLSession, NSJSONSerialization) is the
  only runtime dependency. Do not pull in a third-party HTTP or JSON library.
- **Memory model.** Under ARC. Result arrays are plain NSArray objects the
  caller owns; the client object itself is released normally.
- **Thread safety.** MongrelDBClient is thread-safe: requests serialize through
  a single NSURLSession delegate queue and mutable state is guarded by a lock.
  For high concurrency prefer one client per logical user.
- **Errors.** Methods take `NSError **` out-parameters. Build errors via the
  internal helper. Never leak memory on an error path.
- **Naming.** Standard Objective-C naming conventions: camelCase selectors,
  `MongrelDB*` class prefixes, `MongrelDBError*` error constants.

### Commit messages

- Subject line: imperative mood, <= 72 characters, no trailing period.
- Body: wrap at 72 characters. Explain *why*, not *what*.
- Reference issues with `Fixes #123` / `Refs #123` when applicable.
- **Never** add AI/assistant attribution (no `Co-Authored-By`, no `Generated
  with`, no tool names).

## Security

If you find a vulnerability, **do not** open a public GitHub issue. Report it
privately through GitHub's private vulnerability reporting - the repository's
**Security** tab -> **Report a vulnerability**. The full policy is in
[`SECURITY.md`](SECURITY.md).

## Licensing

The MongrelDB ObjC client is dual-licensed under MIT OR Apache-2.0. By
contributing, you agree that your changes are made available under the same
license.

Thanks again - looking forward to your PR.
