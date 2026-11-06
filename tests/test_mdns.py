#!/usr/bin/env python3
"""Run the actual embedded mDNS check against isolated, read-only fixtures."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = (Path(__file__).resolve().parents[1] / 'setup-nvidia-sync-toolbox.sh').read_text()
BODY = SCRIPT.split("<<'MDNS_CHECK'\n", 1)[1].split('\nMDNS_CHECK', 1)[0]


class MdnsTests(unittest.TestCase):
    def check_fixture(self, config, installed=True, expected=0):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            nss = root / 'nsswitch.conf'
            nss.write_text(config)
            query = root / 'dpkg-query'
            query.write_text('#!/bin/sh\n' + (
                "printf 'install ok installed'\n" if installed else 'exit 1\n'))
            query.chmod(0o755)
            env = dict(os.environ, PATH=f'{root}:/usr/bin:/bin')
            body = BODY.replace('/etc/nsswitch.conf', str(nss))
            before = nss.stat().st_mtime_ns
            # Repeat to ensure the check never changes resolver contents/mtime.
            for _ in range(2):
                result = subprocess.run(['sh', '-s'], input=body, text=True,
                                        capture_output=True, env=env, check=False)
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertEqual(nss.read_text(), config)
                self.assertEqual(nss.stat().st_mtime_ns, before)

    def test_ubuntu_default(self):
        self.check_fixture('hosts: files mdns4_minimal [NOTFOUND=return] dns\n')

    def test_existing_custom_services_preserved(self):
        self.check_fixture('passwd: files systemd\n  hosts : files myhostname mdns4 resolve dns # custom\n')

    def test_dual_stack_module(self):
        self.check_fixture('hosts: files mdns_minimal [NOTFOUND=return] dns\n')

    def test_missing_package(self):
        self.check_fixture('hosts: files mdns4 dns\n', installed=False, expected=1)

    def test_missing_entry(self):
        self.check_fixture('hosts: files dns\n', expected=1)

    def test_commented_entry(self):
        self.check_fixture('# hosts: files mdns4 dns\nhosts: files dns # mdns4\n', expected=1)

    def test_ipv6_only_is_not_ipv4_support(self):
        self.check_fixture('hosts: files mdns6_minimal dns\n', expected=1)

    def test_wrong_database(self):
        self.check_fixture('passwd: files mdns4\nhosts: files dns\n', expected=1)

    def test_dependency_is_explicit(self):
        self.assertIn('apt-get install --yes --no-install-recommends ca-certificates curl gnupg flatpak-xdg-utils libnss-mdns', SCRIPT)
        self.assertIn('check_mdns || failed=1', SCRIPT)


if __name__ == '__main__':
    unittest.main()
