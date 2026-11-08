# Testing

[Development overview](../README.md#development) · [Разработка](../README.ru.md#разработка-и-проверки)

## Host-side checks

Requirements: Python 3.10+, Node.js 22+, POSIX shell and ShellCheck. The host tests use isolated temporary filesystems; they do not require root, SSH, OpenWrt or a live proxy.

```sh
python3 tools/check-manifest.py
python3 tools/check-project.py
python3 -m unittest discover -s tests -p 'test_*.py' -v
node tests/frontend.cjs
sh -n install.sh
shellcheck -s sh install.sh tools/run-router-tests.sh
```

`test_installer.py` runs the actual installer with one fixed root-prefix substitution in a private test copy. Runtime commands are stubbed. It covers successful install/uninstall/restore, preflight without mutation, corrupt payloads, symlinks, destination validation, package ownership, competing operations, partial writes, reload/API failures, and preservation of an external network change during rollback.

`frontend.cjs` uses a small DOM/RPC harness to verify control states, write permissions, validation invalidation, stale edit protection, operation locking and the direct-internet action's availability. It does not replace a browser layout/accessibility check.

## Backend tests on OpenWrt

Use a router you administer, with ucode, the referenced modules and an existing `/usr/bin/mihomo`. Confirm the router is idle before running the tests. These tests do not install the app or deliberately stop/restart the active service.

From your workstation's source checkout:

```sh
sh tools/run-router-tests.sh openwrt
```

Replace `openwrt` with your SSH alias/host. The runner:

1. Creates a private, uniquely named `/tmp` staging directory on that host.
2. Generates modules with test-only paths and a **synthetic config**; no real subscription or secret is copied into the fixture.
3. Runs the real Mihomo `-t` check for valid/invalid YAML and tests guarded fields, job exclusion, stale hashes and no-op application.
4. Runs fault-injection tests for config rollback, failed core readiness, low flash headroom, a partial write, loss of headroom during a write and a successful synthetic gzip update using the copy fallback. Service/routing/API commands are replaced with restrictive stubs, and all mutated files stay under the test directory. Memory budgets and gzip size parsing are tested separately.
5. Compares protected file hashes and service state before/after, then removes its own temporary directory.

The tests may read existing assets through symlinks during validation. They do not change actual network policy, core, config or service state. Unexpected termination can leave the private directory in `/tmp`; its exact prefix is `mihomo-mini-public-tests.`. Inspect the specific abandoned directory before removing it.

Run preflight for the actual installer independently:

```sh
sh install.sh --check
```

## What CI proves

CI checks source metadata, JSON, documentation links, checksum consistency, shell lint, host installer transactions and frontend state logic. It does not run the OpenWrt backend suite or build an SDK package.

Reference-device validation additionally covered the LuCI page in Chrome, config loading/validation, no-op save, stable-release discovery and the four diagnostic probes. A live core upgrade/reboot is a separate controlled test; simulated rollback does not prove all WAN/provider failures recover correctly.

## По-русски

Обычные тесты запускаются на компьютере и используют отдельную временную файловую систему. Для настоящего `mihomo -t` есть `sh tools/run-router-tests.sh openwrt`: он создаёт временные синтетические данные на указанном роутере, а операции службы и сети в тестах отката заменяет заглушками. Рабочий конфиг и подписки в тестовые данные не копируются. Проверки CI не означают, что приложение проверено на всех роутерах, прошивках и сетевых сбоях.

## DNS safety tests

`sh tools/run-dns-tests.sh openwrt` runs isolated DNS state/graph/guard tests with rewritten paths and restrictive kernel/API mocks. It covers nested DIRECT, missing nodes and cycles, protected editor fields, crash state, drift, rule errors, cold-boot intent and late emergency cancellation. The general worker suite additionally exercises failed activation, failed protected reconfiguration and explicit stop through the real worker. Neither suite modifies live DNS or firewall rules. A live WAN capture/client test is separate; mock tests do not establish absence of all client DoH.

### Live LAN client regression check

From a computer behind the router, run `python3 tools/check-dns-client.py --local-name torrserver.home.arpa`. With protection active, it requires A answers in the client fake-IP range `198.18.0.0/16`, exercises both UDP and established TCP to the router and a manually specified external DNS, and verifies the local record through both addresses. It intentionally does not change router state or claim proof against encrypted client DoH. Pair it with a short private capture on the WAN for port 53/853; keep captures out of the repository.
