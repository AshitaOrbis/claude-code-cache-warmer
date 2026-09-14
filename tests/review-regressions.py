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
        for name in ('install.sh', 'cache-warmer.sh', 'replay-warmer.sh', 'shell-guard.sh', 'prefix-proxy.js', 'config.example'):
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
if [[ $* == *daemon-reload* && ${FAIL_RELOAD:-0} == 1 ]]; then echo "mock reload failure" >&2; exit 1; fi
if [[ $* == *'enable prefix-proxy.service'* && ${FAIL_ENABLE:-0} == 1 ]]; then echo "mock enable failure" >&2; exit 1; fi
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
                r = self.run_shell('source shell-guard.sh; echo "${ANTHROPIC_BASE_URL-unset}"', CW_CAPTURE_DIR=str(directory), ANTHROPIC_BASE_URL='http://127.0.0.1:8377', CW_GUARD_ENDPOINT='http://127.0.0.1:8377')
                self.assertEqual(r.stdout.strip(), 'unset')
        self.fake('curl', 'echo nonce')
        nonce.write_text('nonce')
        r = self.run_shell('source shell-guard.sh; CW_PROXY_PORT=9999; rm "$CW_CAPTURE_DIR/.health-nonce"; source shell-guard.sh; echo "${ANTHROPIC_BASE_URL-unset}"; echo nonce > "$CW_CAPTURE_DIR/.health-nonce"; source shell-guard.sh; echo "$ANTHROPIC_BASE_URL"', CW_CAPTURE_DIR=str(directory))
        self.assertEqual(r.stdout.splitlines(), ['unset', 'http://127.0.0.1:9999'])
        nonce.unlink()
        r = self.run_shell('source shell-guard.sh; echo "$ANTHROPIC_BASE_URL"', CW_CAPTURE_DIR=str(directory), ANTHROPIC_BASE_URL='https://intentional.example')
        self.assertEqual(r.stdout.strip(), 'https://intentional.example')

    def test_bq_2472_a_healthy_proxy_keeps_a_route_it_does_not_own(self):
        """bq-2472: the guard selects the proxy only when nothing else has selected a route"""
        directory = self.home / 'captures'
        directory.mkdir()
        (directory / '.health-nonce').write_text('nonce')
        self.fake('curl', 'echo nonce')          # the proxy answers, and it matches
        report = 'source shell-guard.sh; echo "${ANTHROPIC_BASE_URL-unset}"; echo "${CW_GUARD_ENDPOINT-unset}"'
        env = dict(CW_CAPTURE_DIR=str(directory))
        # An unrelated provider survived a FAILED health check already (bq-1998). It has to
        # survive a successful one too: the healthy branch is where the traffic moves.
        r = self.run_shell(report, ANTHROPIC_BASE_URL='https://intentional.example', **env)
        self.assertEqual(r.stdout.splitlines(), ['https://intentional.example', 'unset'], r.stderr)
        self.assertIn('did not set', r.stderr)
        self.assertNotIn('intentional.example', r.stderr)   # never echo a route that may carry credentials
        # A route replaced by hand beside a marker from an earlier guard is the same case.
        r = self.run_shell(report, ANTHROPIC_BASE_URL='https://intentional.example',
                           CW_GUARD_ENDPOINT='http://127.0.0.1:8377', **env)
        self.assertEqual(r.stdout.splitlines(), ['https://intentional.example', 'unset'], r.stderr)
        # An unmarked route that equals the proxy URL is left in place and NOT claimed:
        # the guard cannot withdraw later what it did not export.
        r = self.run_shell(report, ANTHROPIC_BASE_URL='http://127.0.0.1:8377', **env)
        self.assertEqual(r.stdout.splitlines(), ['http://127.0.0.1:8377', 'unset'], r.stderr)
        # Controls: with no route of its own to preserve the guard still routes, still
        # replaces its own route on another port, and treats an empty value as no choice.
        for base in ({}, dict(ANTHROPIC_BASE_URL=''),
                     dict(ANTHROPIC_BASE_URL='http://127.0.0.1:9999',
                          CW_GUARD_ENDPOINT='http://127.0.0.1:9999')):
            with self.subTest(inherited=base):
                r = self.run_shell(report, **dict(env, **base))
                self.assertEqual(r.stdout.splitlines(),
                                 ['http://127.0.0.1:8377', 'http://127.0.0.1:8377'], r.stderr)

    def test_bq_2473_the_guard_follows_the_verified_installed_settings(self):
        """bq-2473: a fresh shell routes to the directory and port the installer verified"""
        record = self.home / '.config/systemd/user/prefix-proxy.settings'
        report = 'source shell-guard.sh; echo "${ANTHROPIC_BASE_URL-unset}"'
        # The documented path: configure, install, then source the guard in a NEW shell that
        # carries no CW_* at all. Installation verifying the right proxy while the next entry
        # point resolves different settings is the whole finding.
        custom = self.home / 'custom-captures'
        self.config(f'CAPTURE_DIR="{custom}"\n')
        self.assertEqual(self.install(NONCE_DIR=str(custom)).returncode, 0)
        r = self.run_shell(report)
        self.assertEqual(r.stdout.strip(), 'http://127.0.0.1:8377', r.stderr)
        self.assertEqual(record.read_text(), f'CAPTURE_DIR={custom}\nPROXY_PORT=8377\n')
        self.assertEqual(oct(record.stat().st_mode & 0o777), '0o600')
        # An explicit CW_* in the shell still overrides the record, and still fails closed.
        r = self.run_shell(report, CW_CAPTURE_DIR=str(self.home / 'elsewhere'))
        self.assertEqual(r.stdout.strip(), 'unset', r.stderr)
        # A custom port, proved against a probe that answers on that port only.
        self.fake('curl', 'case "$*" in *127.0.0.1:9310/warmer-health*) echo nonce ;; *) exit 7 ;; esac')
        self.config('PROXY_PORT=9310\n')
        self.assertEqual(self.install().returncode, 0)
        r = self.run_shell(report)
        self.assertEqual(r.stdout.strip(), 'http://127.0.0.1:9310', r.stderr)
        # Settings that exist only in the installer's invocation reach the guard too.
        override = self.home / 'invocation-only'
        self.fake('curl', 'echo nonce')
        self.config()
        self.assertEqual(self.install(CW_CAPTURE_DIR=str(override), NONCE_DIR=str(override)).returncode, 0)
        r = self.run_shell(report)
        self.assertEqual(r.stdout.strip(), 'http://127.0.0.1:8377', r.stderr)
        self.assertIn(f'CAPTURE_DIR={override}', record.read_text())
        # A value the guard cannot trust is never used: each unusable field falls back
        # to its built-in default instead of reaching the endpoint or the nonce path.
        # A relative directory therefore looks in the default store (no nonce, no
        # route); a bad port leaves the default port, never 'http://127.0.0.1:nine'.
        for bad, expected in ((f'CAPTURE_DIR=relative\nPROXY_PORT=8377\n', 'unset'),
                              (f'CAPTURE_DIR={override}\nPROXY_PORT=nine\n', 'http://127.0.0.1:8377'),
                              (f'CAPTURE_DIR={override}\nPROXY_PORT=70000\n', 'http://127.0.0.1:8377'),
                              (f'CAPTURE_DIR={override}\nPROXY_PORT=0\n', 'http://127.0.0.1:8377'),
                              (f'PROXY_PORT=8377\n', 'unset'),
                              (f'junk\nCAPTURE_DIR={override}\nUNKNOWN=x\n', 'http://127.0.0.1:8377')):
            with self.subTest(record=bad):
                record.write_text(bad)
                r = self.run_shell(report)
                self.assertEqual(r.stdout.strip(), expected, r.stderr)

    def test_bq_2473_only_verified_settings_are_published(self):
        """bq-2473: staged, unverified and engineless installs publish no settings"""
        record = self.home / '.config/systemd/user/prefix-proxy.settings'
        report = 'source shell-guard.sh; echo "${ANTHROPIC_BASE_URL-unset}"'
        running = self.home / 'running-captures'
        self.config(f'CAPTURE_DIR="{running}"\n')
        self.assertEqual(self.install(NONCE_DIR=str(running)).returncode, 0)
        self.assertEqual(self.run_shell(report).stdout.strip(), 'http://127.0.0.1:8377')
        applied = record.read_text()
        # --defer-restart stages a new port and leaves the old proxy running. The record has
        # to keep describing the proxy that is actually up, not the one that is staged.
        self.config(f'CAPTURE_DIR="{running}"\nPROXY_PORT=9310\n')
        self.assertIn('restart required', self.install('--defer-restart').stdout)
        self.assertEqual(record.read_text(), applied)
        self.assertEqual(self.run_shell(report).stdout.strip(), 'http://127.0.0.1:8377')
        # A restart whose nonce check fails publishes nothing and withdraws what it had.
        staged = self.home / 'staged-captures'
        self.config(f'CAPTURE_DIR="{staged}"\n')
        self.assertNotEqual(self.install(BAD_HEALTH='1', NONCE_DIR=str(staged)).returncode, 0)
        self.assertFalse(record.exists())
        self.assertEqual(self.run_shell(report).stdout.strip(), 'unset')
        # v2 has no capture proxy, and an uninstall leaves none either.
        self.fake('tmux', 'exit 0')
        self.config()
        self.assertEqual(self.install().returncode, 0)
        self.assertTrue(record.exists())
        self.assertEqual(self.install('--engine v2 --force-v2').returncode, 0)
        self.assertFalse(record.exists())
        self.assertEqual(self.install().returncode, 0)
        self.assertTrue(record.exists())
        self.assertEqual(self.install('--uninstall').returncode, 0)
        self.assertFalse(record.exists())

    def test_bq_1996_config_cannot_overwrite_installer_state(self):
        """bq-1996: config assignments beyond the shared settings stay in the config's own scope"""
        self.config(f'ENGINE=v2\nUNIT_DIR="{self.home}/alternate-units"\nDEFER_RESTART=1\nREPO_DIR=/nonexistent\n')
        r = self.install()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('cache-warmer v3 installed', r.stdout)
        self.assertNotIn('restart required', r.stdout)
        self.assertTrue((self.home / '.config/systemd/user/prefix-proxy.service').exists())
        self.assertFalse((self.home / 'alternate-units').exists())

    def test_bq_1997_failed_update_cannot_be_certified_by_rollback(self):
        """bq-1997: a failed or deferred update withdraws the applied fingerprint"""
        calls = self.base / 'calls'
        self.config()
        self.assertEqual(self.install().returncode, 0)
        self.config('PRUNE_HOURS=2\n')
        self.assertNotEqual(self.install(BAD_HEALTH='1').returncode, 0)
        self.config()                      # roll the setting back to the verified value
        calls.write_text('')
        self.assertEqual(self.install().returncode, 0)
        self.assertIn('restart prefix-proxy.service', calls.read_text())
        self.config('PRUNE_HOURS=3\n')
        self.assertIn('restart required', self.install('--defer-restart').stdout)
        self.config()
        calls.write_text('')
        self.assertEqual(self.install().returncode, 0)
        self.assertIn('restart prefix-proxy.service', calls.read_text())

    def test_bq_1997_active_proxy_is_enabled_for_future_logins(self):
        """bq-1997: an already-active proxy is enabled, not only restarted"""
        calls = self.base / 'calls'
        self.config()
        self.assertEqual(self.install().returncode, 0)
        calls.write_text('')
        self.assertEqual(self.install().returncode, 0)
        self.assertIn('--user enable prefix-proxy.service', calls.read_text().splitlines())

    def test_bq_1997_intermediate_failure_reports_the_stopped_timer(self):
        """bq-1997: an error after the timer is paused says it is still stopped"""
        self.config()
        self.assertEqual(self.install().returncode, 0)
        r = self.install(FAIL_RELOAD='1')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('stop cache-warmer.timer', (self.base / 'calls').read_text())
        self.assertIn('cache-warmer.timer and it is still stopped', r.stderr)

    def test_bq_1998_unmarked_matching_route_is_left_with_a_notice(self):
        """bq-1998: a matching URL without the marker is not assumed to be the guard's"""
        directory = self.home / 'captures'
        directory.mkdir()
        r = self.run_shell('source shell-guard.sh; echo "${ANTHROPIC_BASE_URL-unset}"', CW_CAPTURE_DIR=str(directory), ANTHROPIC_BASE_URL='http://127.0.0.1:8377')
        self.assertEqual(r.stdout.strip(), 'http://127.0.0.1:8377')
        self.assertIn('was not set by this guard', r.stderr)

    def test_bq_1995_integer_settings_are_decimal(self):
        """bq-1995: a zero-prefixed threshold means the same to the range check and the classifier"""
        for value, refused in (('0120', True), ('080', False)):
            with self.subTest(value=value):
                config = self.base / f'warmer-config-{value}'
                config.write_text(f'ENABLED=0\nMIN_CACHE_READ_PCT={value}\n')
                r = self.run_shell('bash replay-warmer.sh --dry-run', CW_CONFIG=str(config))
                self.assertEqual('MIN_CACHE_READ_PCT must be between 80 and 100' in r.stderr, refused, r.stderr)

    def test_bq_1997_interrupted_update_leaves_no_fingerprint_to_trust(self):
        """bq-1997: a failure after the new unit is written cannot let a rollback skip the restart"""
        calls = self.base / 'calls'
        self.config()
        self.assertEqual(self.install().returncode, 0)
        self.config('PRUNE_HOURS=2\n')
        # The new unit is written and reloaded, then enabling fails. systemd could now
        # restart the proxy from that unit on its own (Restart=always).
        self.assertNotEqual(self.install(FAIL_ENABLE='1').returncode, 0)
        self.config()
        calls.write_text('')
        self.assertEqual(self.install().returncode, 0)
        self.assertIn('restart prefix-proxy.service', calls.read_text())

    def test_bq_1996_overrides_replace_unusable_config_values(self):
        """bq-1996: an explicit override replaces an empty or multi-line config value before validation"""
        units = self.home / '.config/systemd/user'
        self.config('PROXY_PORT=""\n')
        r = self.install(CW_PROXY_PORT='8377')
        self.assertEqual(r.returncode, 0, r.stderr)
        override = str(self.home / 'override')
        self.config('CAPTURE_DIR="/tmp/first\nsecond"\n')
        r = self.install(CW_CAPTURE_DIR=override, NONCE_DIR=override)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn(override, (units / 'prefix-proxy.service').read_text())
        self.config('PROXY_PORT=""\n')
        self.assertEqual(self.install().returncode, 2)


if __name__ == '__main__':
    unittest.main(verbosity=2)
