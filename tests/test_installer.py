"""Exercise the real shell installer in isolated fake router filesystems.

The shipping installer has no test/root override. A private copy receives a
single TARGET_ROOT substitution; command stubs cannot access a real router.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import textwrap
import unittest

PROJECT = Path(__file__).resolve().parents[1]


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='mihomo-installer-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.dist, self.root, self.bin = [self.base / p for p in ('source', 'router', 'bin')]
        self.bin.mkdir()
        shutil.copytree(PROJECT, self.dist, ignore=shutil.ignore_patterns('.git', '__pycache__', 'node_modules'))
        self.script = self.dist / 'install.sh'
        text = self.script.read_text()
        self.assertEqual(text.count("TARGET_ROOT=''"), 1)
        self.script.write_text(text.replace("TARGET_ROOT=''", f"TARGET_ROOT='{self.root}'"))
        self.destinations = [line.split()[2] for line in (self.dist / 'install.files').read_text().splitlines() if line and not line.startswith('#')]
        for folder in ('tmp', 'overlay', 'etc/config', 'etc/init.d', 'etc/mihomo', 'usr/bin', 'usr/libexec'):
            (self.root / folder).mkdir(parents=True, exist_ok=True)
        for name in ('network', 'wireless', 'dhcp', 'firewall', 'mihomo'):
            (self.root / 'etc/config' / name).write_text('synthetic fixture\n')
        (self.root / 'etc/openwrt_release').write_text("DISTRIB_ID='OpenWrt'\n")
        (self.root / 'etc/mihomo/config.yaml').write_text('synthetic YAML checked by the ucode stub\n')
        (self.root / 'etc/mihomo/tproxy.nft').write_text('table inet mihomo_tproxy_safe {}\n')
        for path in ('usr/bin/mihomo', 'usr/libexec/mihomo-safe-run', 'etc/init.d/mihomo'):
            self.executable(self.root / path, '#!/bin/sh\nexit 0\n')
        (self.root / 'usr/libexec/mihomo-safe-run').write_text('#!/bin/sh\n# mihomo_tproxy_safe\nexit 0\n')
        (self.root / 'etc/init.d/mihomo').write_text('#!/bin/sh\n# mihomo-safe-run\nexit 0\n')
        self.log = self.base / 'commands.log'
        self.env = dict(os.environ, PATH=str(self.bin) + ':' + os.environ['PATH'], NO_COLOR='1',
                        TEST_ROUTER=str(self.root), TEST_LOG=str(self.log), TEST_ONCE=str(self.base / 'once'))
        self.executable(self.bin / 'id', '#!/bin/sh\necho 0\n')
        self.executable(self.bin / 'uname', '#!/bin/sh\necho aarch64\n')
        self.executable(self.bin / 'chown', '#!/bin/sh\nexit 0\n')
        self.executable(self.bin / 'df', '#!/bin/sh\nprintf "Filesystem 1024-blocks Used Available Capacity Mounted\\nfixture 999999 1 999998 1%% /\\n"\n')
        self.python_stub('ucode', '''
import os, sys
if os.environ.get('TEST_UCODE_FAIL')=='1': sys.exit(1)
for arg in sys.argv:
 if arg.startswith('file_path='):
  print(oct(os.stat(arg.split('=',1)[1]).st_mode & 0o777)[2:])
  break
''')
        self.executable(self.bin / 'sleep', '#!/bin/sh\nexit 0\n')
        self.executable(self.bin / 'apk', '#!/bin/sh\nexit "${TEST_APK_STATUS:-1}"\n')
        self.executable(self.bin / 'uci', '''#!/bin/sh
case "$3" in
  mihomo.main.conffile) echo /etc/mihomo/config.yaml ;;
  mihomo.main.workdir) echo /etc/mihomo ;;
  mihomo.main.user) echo root ;;
  *) exit 1 ;;
esac
''')
        self.executable(self.root / 'etc/init.d/rpcd', '''#!/bin/sh
printf 'rpcd %s\n' "$*" >> "$TEST_LOG"
if [ "${TEST_RELOAD_FAIL:-0}" = 1 ] && [ ! -e "$TEST_ONCE" ]; then
    touch "$TEST_ONCE"
    exit 1
fi
exit 0
''')
        self.python_stub('stat', '''
import os, sys
p = os.stat(sys.argv[-1]); key = sys.argv[2]
print(p.st_size if key == '%s' else oct(p.st_mode & 0o777)[2:])
''')
        self.python_stub('flock', '''
import fcntl, sys
try: fcntl.flock(int(sys.argv[-1]), fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError: sys.exit(1)
''')
        self.python_stub('jsonfilter', '''
import json, sys
d=json.load(open(sys.argv[sys.argv.index('-i')+1])); q=sys.argv[-1]
if q=='@.ok': print('true' if d.get('ok') else 'false')
elif q=='@.pid': print(d['pid'])
elif 'pid' in q: print(d['mihomo']['instances']['mihomo.main']['pid'])
''')
        self.python_stub('ubus', '''
import json, os, sys
from pathlib import Path
with open(os.environ['TEST_LOG'],'a') as f: f.write('ubus '+ ' '.join(sys.argv[1:])+'\\n')
if sys.argv[2:4]==['service','list']:
 print(json.dumps({'mihomo':{'instances':{'mihomo.main':{'running':True,'pid':123}}}}))
elif sys.argv[2:4]==['mihomo-mini','status']:
 if os.environ.get('TEST_RPC_FAIL')=='1': sys.exit(1)
 if os.environ.get('TEST_EXTERNAL_CHANGE')=='1':
  Path(os.environ['TEST_ROUTER']+'/etc/config/network').write_text('external change\\n')
 print(json.dumps({'ok':True}))
else: sys.exit(1)
''')
        real_cp = shutil.which('cp')
        self.python_stub('cp', f'''
import os, sys
from pathlib import Path
target=sys.argv[-1]
if os.environ.get('TEST_COPY_FAIL')=='1' and '/usr/share/rpcd/ucode/' in target and not Path(os.environ['TEST_ONCE']).exists():
 Path(os.environ['TEST_ONCE']).touch()
 Path(target).write_text('partial write')
 sys.exit(1)
os.execv({real_cp!r}, [{real_cp!r}]+sys.argv[1:])
''')
        # Runtime dependencies checked with command -v; nothing invokes these.
        for name in ('curl', 'nft', 'ip', 'setsid', 'gzip', 'nslookup'):
            self.executable(self.bin / name, '#!/bin/sh\nexit 0\n')

    def executable(self, path, text):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        path.chmod(0o755)

    def python_stub(self, name, source):
        import sys
        self.executable(self.bin / name, f'#!{sys.executable}\n' + textwrap.dedent(source).lstrip())

    def run_installer(self, *args, success=True, **env):
        r = subprocess.run(['sh', str(self.script), *args], text=True, capture_output=True,
                           env=dict(self.env, **env), timeout=30)
        self.assertEqual(r.returncode == 0, success, r.stdout + r.stderr)
        return r

    def app_snapshot(self):
        return {p: (self.root / p).read_bytes() if (self.root / p).is_file() else None for p in self.destinations}

    def old_installation(self):
        for i, path in enumerate(self.destinations):
            p = self.root / path
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(f'previous file {i}\n')
            p.chmod(0o755 if path.endswith('mihomo-mini-worker') else 0o644)

    def assert_unlocked(self):
        self.assertFalse((self.root / 'tmp/mihomo-mini/lock').exists())

    def test_help_works_off_router(self):
        r = subprocess.run(['sh', str(PROJECT / 'install.sh'), '--help'], capture_output=True, text=True, timeout=10)
        self.assertEqual(r.returncode, 0)
        self.assertIn('--restore', r.stdout)

    def test_check_does_not_install_or_reload(self):
        self.run_installer('--check')
        self.assertTrue(all(v is None for v in self.app_snapshot().values()))
        self.assertFalse((self.root / 'etc/mihomo-mini').exists())
        self.assertFalse(self.log.exists())

    def test_install_and_uninstall_preserve_network(self):
        config = (self.root / 'etc/mihomo/config.yaml').read_bytes()
        self.run_installer('--yes')
        self.assertTrue(all(v is not None for v in self.app_snapshot().values()))
        self.assertEqual((self.root / 'usr/libexec/mihomo-mini-worker').stat().st_mode & 0o777, 0o755)
        self.run_installer('--uninstall', '--yes')
        self.assertTrue(all(v is None for v in self.app_snapshot().values()))
        self.assertEqual((self.root / 'etc/mihomo/config.yaml').read_bytes(), config)
        self.assert_unlocked()
        self.assertNotIn('restart', self.log.read_text())
        self.assertNotIn('start', self.log.read_text())
        self.assertNotIn('stop', self.log.read_text())

    def test_payload_tampering_is_rejected(self):
        p = self.dist / 'root/usr/share/ucode/mihomo-mini.uc'
        p.write_text(p.read_text() + '\n// corrupt\n')
        self.run_installer('--yes', success=False)
        self.assertTrue(all(v is None for v in self.app_snapshot().values()))

    def test_symlink_destination_is_rejected(self):
        (self.root / 'usr/share').mkdir()
        outside = self.base / 'outside'
        outside.mkdir()
        (self.root / 'usr/share/ucode').symlink_to(outside, target_is_directory=True)
        self.run_installer('--yes', success=False)
        self.assertEqual(list(outside.iterdir()), [])

    def test_foreign_destination_in_manifest_is_rejected(self):
        p = self.dist / 'install.files'
        p.write_text(p.read_text().replace('usr/share/ucode/mihomo-mini.uc\n', 'etc/config/network\n', 1))
        self.run_installer('--yes', success=False)

    def test_noninteractive_install_requires_yes(self):
        r = self.run_installer(success=False)
        self.assertIn('requires --yes', r.stderr)

    def test_active_job_blocks_installation(self):
        (self.root / 'tmp/mihomo-mini/lock').mkdir(parents=True)
        self.run_installer('--yes', success=False)
        self.assertTrue(all(v is None for v in self.app_snapshot().values()))

    def test_interrupted_installer_lock_can_be_reclaimed(self):
        lock = self.root / 'tmp/mihomo-mini/lock'
        lock.mkdir(parents=True)
        (lock / 'owner.json').write_text('{"pid":999999999,"id":"job-installer","created":1}')
        self.run_installer('--check')
        self.assertTrue(lock.exists(), 'check must not remove a stale lock')
        self.run_installer('--yes')
        self.assert_unlocked()

    def test_package_owned_files_are_not_replaced(self):
        self.old_installation()
        before = self.app_snapshot()
        self.run_installer('--check', success=False, TEST_APK_STATUS='0')
        self.assertEqual(self.app_snapshot(), before)

    def test_failed_compile_leaves_previous_installation(self):
        self.old_installation()
        before = self.app_snapshot()
        self.run_installer('--yes', success=False, TEST_UCODE_FAIL='1')
        self.assertEqual(self.app_snapshot(), before)

    def test_partial_write_rolls_back_and_cleans_staging(self):
        self.old_installation()
        before = self.app_snapshot()
        self.run_installer('--yes', success=False, TEST_COPY_FAIL='1')
        self.assertEqual(self.app_snapshot(), before)
        self.assertEqual(list(self.root.rglob('*.mihomo-mini-new.*')), [])
        self.assert_unlocked()

    def test_reload_failure_rolls_back(self):
        self.old_installation()
        before = self.app_snapshot()
        self.run_installer('--yes', success=False, TEST_RELOAD_FAIL='1')
        self.assertEqual(self.app_snapshot(), before)
        self.assert_unlocked()

    def test_rpc_failure_rolls_back_new_installation(self):
        self.run_installer('--yes', success=False, TEST_RPC_FAIL='1')
        self.assertTrue(all(v is None for v in self.app_snapshot().values()))
        self.assert_unlocked()

    def test_external_network_change_is_not_overwritten_by_rollback(self):
        self.old_installation()
        before = self.app_snapshot()
        self.run_installer('--yes', success=False, TEST_EXTERNAL_CHANGE='1')
        self.assertEqual(self.app_snapshot(), before)
        self.assertEqual((self.root / 'etc/config/network').read_text(), 'external change\n')

    def test_changed_owned_files_block_uninstall(self):
        self.run_installer('--yes')
        p = self.root / self.destinations[0]
        p.write_text('local changes\n')
        self.run_installer('--uninstall', '--yes', success=False)
        self.assertEqual(p.read_text(), 'local changes\n')

    def test_restore_returns_previous_application(self):
        self.old_installation()
        before = self.app_snapshot()
        self.run_installer('--yes')
        backup = next((self.root / 'etc/mihomo-mini').glob('install-backup-*'))
        self.run_installer('--restore', str(backup), '--yes')
        self.assertEqual(self.app_snapshot(), before)
        self.assert_unlocked()


if __name__ == '__main__':
    unittest.main()
