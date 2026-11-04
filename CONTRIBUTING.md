# Contributing

Small, reviewable changes are welcome. Describe the concrete problem, the resulting behavior and the tests you ran. For routing/service changes, describe the failure path and recovery behavior as well.

## Before changing code

Read [compatibility](docs/compatibility.md), [architecture](docs/architecture.md) and [testing](docs/testing.md). Do not broaden supported router integrations without matching validation and recovery tests. Keep Russian and English README behavior/requirements in sync.

The installer must remain English, POSIX-shell compatible and usable in BusyBox ash. It must never install a core, start Mihomo or change network configuration as an installation side effect. No automatic enabling of TProxy or autostart.

## Local checks

```sh
python3 tools/check-manifest.py --write  # after intentionally editing a payload file
python3 tools/check-project.py
python3 -m unittest discover -s tests -p 'test_*.py' -v
node tests/frontend.cjs
sh -n install.sh
shellcheck -s sh install.sh
```

Review a checksum diff rather than regenerating it to hide unexplained changes. Use test fixtures; do not commit exports from a live router. Avoid new dependencies unless they solve a clear problem for the supported OpenWrt environment.

## Code and change scope

- Follow the surrounding tabs in JavaScript/ucode and four-space shell/Python indentation.
- Keep RPC operations and destination paths explicit. Do not add arbitrary shell/path endpoints.
- Preserve mode and secret-file permissions across success, failure and cancellation.
- Test interrupted writes, stale config edits, service failures and recovery when relevant.
- Explain limitations honestly; a mocked test is not a live hardware test.
- Use a focused branch and pull request. Never include actual credentials, tokens or subscription endpoints.

Contributions are provided under the repository's [MIT license](LICENSE). No separate contributor agreement is required.
