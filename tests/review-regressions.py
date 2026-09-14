"""Offline bq-1994 through bq-1998 regressions; all writes stay in fixtures."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class Review(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='cw-review-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.repo = self.base / 'repo'
        self.repo.mkdir()
        for name in ('install.sh', 'cache-warmer.sh', 'shell-guard.sh', 'prefix-proxy.js', 'config.example'):
            shutil.copy2(ROOT / name, self.repo / name)
        (self.repo / 'lib').mkdir()
        for name in ('units.sh', 'classify.sh', 'jsonl.py', 'receipt.jq'):
            if (ROOT / 'lib' / name).exists():
                shutil.copy2(ROOT / 'lib' / name, self.repo / 'lib' / name)
        (self.repo / 'tests').mkdir()
        shutil.copy2(ROOT / 'tests/live-replay-gate.sh', self.repo / 'tests/live-replay-gate.sh')
        self.home = self.base / 'home'
        self.home.mkdir()
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        self.env = dict(HOME=str(self.home), PATH=f'{self.bin}:/usr/bin:/bin',
                        TMPDIR=str(self.base), LANG='C.UTF-8')
        self.env['CALLS'] = str(self.base / 'calls')
        self.env['NONCE_DIR'] = str(self.home / 'captures')
        self.fake('node', 'exit 0')
        self.fake('claude', 'echo 2.1.200')
        self.fake('systemctl', '''echo "$*" >> "$CALLS"
if [[ $* == *is-active* ]]; then [[ -f "$HOME/active" ]]; exit; fi
if [[ $* == *'restart prefix-proxy.service'* || $* == *'enable --now prefix-proxy.service'* ]]; then
  mkdir -p "$NONCE_DIR"; echo nonce > "$NONCE_DIR/.health-nonce"; touch "$HOME/active"
fi''')
        self.fake('curl', 'echo probe >> "$CALLS"; [[ ${BAD_HEALTH:-0} == 0 ]] && echo nonce || echo wrong')

    def fake(self, name, body):
        p = self.bin / name
        p.write_text('#!/bin/bash\nset -euo pipefail\n' + body + '\n')
        p.chmod(0o755)

    def run_shell(self, code, **env):
        return subprocess.run(['bash', '-c', code], cwd=self.repo, env=dict(self.env, **env), text=True, capture_output=True)

    def config(self, extra=''):
        (self.repo / 'config').write_text(f'ENABLED=1\nCAPTURE_DIR="{self.home}/captures"\nPRUNE_HOURS=1\n' + extra)

    def install(self, args='', **env):
        return self.run_shell(f'bash install.sh {args}', **env)

    def test_bq_1994_validated_bypass(self):
        """bq-1994: validated bypass"""
        for flags, expected in [('--dangerously-skip-permissions', '1'), ('--permission-mode bypassPermissions', '1'), ('--permission-mode=bypassPermissions', '1'), ('--permission-mode plan', '0'), ('--permission-mode=acceptEdits', '0'), ('--model bypassPermissions', '0'), ('--model x-bypassPermissions', '0'), ('-- --dangerously-skip-permissions', '0')]:
            with self.subTest(flags=flags):
                r = self.run_shell('source cache-warmer.sh; record_authoritative_process 1 /fixture "" claude --resume 11111111-1111-1111-1111-111111111111 ' + flags + '; echo "${RESUME_SID_BYPASS[11111111-1111-1111-1111-111111111111]}"', CACHE_WARMER_SOURCE_ONLY='1')
                self.assertEqual(r.stdout.strip(), expected, r.stderr)

    def test_bq_1995_gate(self):
        """bq-1995: gate"""
        capture = self.repo / 'capture.json'
        capture.write_text('{}')
        capture.with_suffix('.hdrs.json').write_text('{}')
        good = dict(http=200, cache_read=900, cache_creation=0, input_tokens=100, output_tokens=1, cap=1)
        cases = [(good, True), (dict(good, aborted=False), True), (dict(good, cache_read=1, input_tokens=100000), False), (dict(good, output_tokens=None, cap=None, aborted=True), False), ({k: v for k, v in dict(good, output_tokens=None).items() if k != 'input_tokens'}, False)]
        for field in ('cap', 'output_tokens'):
            cases.append(({k: v for k, v in good.items() if k != field}, False))
        for field, value in [('cap', None), ('cap', 0), ('cap', 1.5), ('output_tokens', '1'), ('output_tokens', -1), ('aborted', True), ('cache_read', True), ('input_tokens', None)]:
            cases.append((dict(good, **{field: value}), False))
        for receipt, passes in cases:
            with self.subTest(receipt=receipt):
                (self.repo / 'warm-replay.py').write_text('print(' + repr(json.dumps(receipt)) + ')\n')
                r = self.run_shell('bash tests/live-replay-gate.sh capture.json', CW_LIVE='1')
                self.assertEqual(r.returncode == 0, passes, r.stdout + r.stderr)
        self.assertNotEqual(self.run_shell('bash tests/live-replay-gate.sh capture.json').returncode, 0)

    def test_bq_1996_config_and_precedence(self):
        """bq-1996: config and precedence"""
        self.config()
        r = self.install()
        self.assertEqual(r.returncode, 0, r.stderr)
        units = self.home / '.config/systemd/user'
        self.assertIn('retention 1h', r.stdout)
        self.assertIn('scheduled warming enabled (ENABLED=1)', r.stdout)
        self.assertIn(str(self.home / 'captures'), (units / 'prefix-proxy.service').read_text())
        self.assertIn('CW_PRUNE_HOURS=1', (units / 'cache-warmer.service').read_text())
        override = str(self.home / 'override')
        r = self.install(CW_CAPTURE_DIR=override, CW_PRUNE_HOURS='2', NONCE_DIR=override)
        self.assertEqual(r.returncode, 0, r.stderr)
        for name in ('prefix-proxy.service', 'cache-warmer.service'):
            self.assertIn(override, (units / name).read_text())
            self.assertIn('CW_PRUNE_HOURS=2', (units / name).read_text())

    def test_bq_1996_invalid(self):
        """bq-1996: invalid"""
        for extra in ('PRUNE_HOURS=0\n', 'PRUNE_HOURS=abc\n', 'CAPTURE_DIR=relative\n'):
            self.config(extra)
            self.assertNotEqual(self.install().returncode, 0)

    def test_bq_1997_lifecycle(self):
        """bq-1997: lifecycle"""
        self.config()
        self.assertEqual(self.install().returncode, 0)
        calls = self.base / 'calls'
        self.assertNotIn('restart prefix-proxy', calls.read_text())
        calls.write_text('')
        self.assertEqual(self.install().returncode, 0)
        self.assertNotIn('restart prefix-proxy', calls.read_text())
        for change in ('code', 'settings'):
            with self.subTest(change=change):
                if change == 'code':
                    with (self.repo / 'prefix-proxy.js').open('a') as stream:
                        stream.write('\n// changed fixture code\n')
                else:
                    self.config('PRUNE_HOURS=2\n')
                calls.write_text('')
                self.assertEqual(self.install().returncode, 0)
                events = calls.read_text()
                self.assertIn('restart prefix-proxy.service', events)
                self.assertLess(events.index('restart prefix-proxy.service'), events.index('probe'))
        self.config('PRUNE_HOURS=3\n')
        calls.write_text('')
        r = self.install('--defer-restart')
        self.assertIn('restart required', r.stdout)
        self.assertNotIn('restart prefix-proxy', calls.read_text())
        self.assertNotIn('v3 installed', r.stdout)
        r = self.install(BAD_HEALTH='1')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('restart prefix-proxy.service', calls.read_text())
        self.assertNotIn('v3 installed', r.stdout)
        calls.write_text('')
        r = self.install()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('restart prefix-proxy.service', calls.read_text())
        self.assertIn('stop cache-warmer.timer', calls.read_text())

    def test_bq_1998_inherited_and_repeated(self):
        """bq-1998: inherited and repeated"""
        directory = self.home / 'captures'
        directory.mkdir()
        for condition in ('missing', 'empty', 'probe', 'mismatch'):
            with self.subTest(condition=condition):
                nonce = directory / '.health-nonce'
                nonce.write_text('' if condition == 'empty' else 'nonce')
                if condition == 'missing':
                    nonce.unlink()
                self.fake('curl', 'exit 1' if condition == 'probe' else 'echo wrong')
                r = self.run_shell('source shell-guard.sh; echo "${ANTHROPIC_BASE_URL-unset}"', CW_CAPTURE_DIR=str(directory), ANTHROPIC_BASE_URL='http://127.0.0.1:8377')
                self.assertEqual(r.stdout.strip(), 'unset')
        self.fake('curl', 'echo nonce')
        nonce.write_text('nonce')
        r = self.run_shell('source shell-guard.sh; CW_PROXY_PORT=9999; rm "$CW_CAPTURE_DIR/.health-nonce"; source shell-guard.sh; echo "${ANTHROPIC_BASE_URL-unset}"; echo nonce > "$CW_CAPTURE_DIR/.health-nonce"; source shell-guard.sh; echo "$ANTHROPIC_BASE_URL"', CW_CAPTURE_DIR=str(directory))
        self.assertEqual(r.stdout.splitlines(), ['unset', 'http://127.0.0.1:9999'])
        nonce.unlink()
        r = self.run_shell('source shell-guard.sh; echo "$ANTHROPIC_BASE_URL"', CW_CAPTURE_DIR=str(directory), ANTHROPIC_BASE_URL='https://intentional.example')
        self.assertEqual(r.stdout.strip(), 'https://intentional.example')


if __name__ == '__main__':
    unittest.main(verbosity=2)
