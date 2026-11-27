# Contributing to Lumora

Questions and ideas belong in [Discussions](https://github.com/hoangtuvungcao/lumora/discussions).
Use [Issues](https://github.com/hoangtuvungcao/lumora/issues) for reproducible bugs.
Vietnamese and English reports are welcome.

Describe the problem, expected behavior and the smallest proposed change before opening a
pull request. Keep unrelated formatting and generated assets out of the change. The existing
app/core license and the SDK's separate MIT license remain in force; public access to source
does not grant additional redistribution rights.

## Checks

- Rust: from `core/`, run relevant tests. The baseline is `cargo test --workspace --locked`
  and `cargo clippy --workspace --all-targets --locked -- -D warnings`.
- Flutter: use the Flutter version pinned in `.github/workflows/build.yml`, then run
  `flutter analyze` and relevant tests from `app/`.
- Website: run `python3 branding/tools/build_pages.py`, `bash branding/tools/make_dist.sh`
  and `python3 branding/tools/check_dist.py dist/landing`.
- Run `git diff --check` and report which checks actually ran.

User-facing strings need Vietnamese and English equivalents. Add a focused regression test
when changing behavior. See `docs/src/dev/testing.md` for broader suites.

## Safe bug reports and screenshots

Include app version, operating system, reproduction steps, connection type and visible error.
Use synthetic conversations and test identities in screenshots. Remove personal names,
handles, IP addresses, message contents, private file names and device identifiers.

Never post recovery phrases, private keys, passwords, tokens, database files, backups,
complete data directories or unredacted logs. For vulnerabilities, follow [SECURITY.md](SECURITY.md).
