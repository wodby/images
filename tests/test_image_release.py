#!/usr/bin/env python3
"""Test GitHub Release creation against real annotated Git tags and a fake API."""

import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import HTTPError

import yaml

SPEC = importlib.util.spec_from_file_location(
    'image_release', Path(__file__).resolve().parents[1] / 'scripts/image_release.py')
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)
NOTES = 'Update Alpine packages\n\n- Upgrade zlib to fix a CVE.\n- Preserve configuration.\n'


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.old = Path.cwd()
        self.addCleanup(os.chdir, self.old)
        os.chdir(self.temp.name)
        release.git('init', '-q')
        for name, value in [('user.name', 'Test'), ('user.email', 'test@example.invalid'),
                            ('commit.gpgsign', 'false'), ('tag.gpgsign', 'false')]:
            release.git('config', name, value)
        Path('.image-release-format').write_text('revision\n')
        release.git('add', '.')
        release.git('commit', '-qm', 'Fixture')
        self.sha = release.git('rev-parse', 'HEAD')
        release.git('init', '--bare', '-q', 'remote.git')
        release.git('remote', 'add', 'origin', str(Path('remote.git').resolve()))
        self.tag()
        self.existing = {'tag_name': 'r0', 'draft': False,
                         'html_url': 'https://github.com/wodby/test/releases/tag/r0'}

    def tag(self, tag='r0', notes=NOTES, signed=False):
        release.git('tag', '-f', '-s' if signed else '-a', tag, '-m', notes)
        release.git('push', '--force', 'origin', f'refs/tags/{tag}')

    def publish(self):
        return release.publish('wodby/test', 'r0', self.sha)

    def test_create_copies_notes_and_exact_name(self):
        with patch.object(release, 'api', side_effect=[(404, None), (201, self.existing)]) as api:
            self.assertEqual(self.publish(), self.existing['html_url'])
        self.assertEqual(api.call_args_list[1].args, (
            'POST', 'repos/wodby/test/releases', {
                'tag_name': 'r0', 'name': 'r0', 'body': NOTES.strip(),
                'draft': False, 'prerelease': False, 'generate_release_notes': False,
                'make_latest': 'legacy'}))

    def test_signed_annotation_preserves_markdown_without_signature(self):
        subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', 'key'], check=True)
        release.git('config', 'gpg.format', 'ssh')
        release.git('config', 'gpg.ssh.program', 'ssh-keygen')
        release.git('config', 'user.signingkey', str(Path('key').resolve()))
        self.tag(signed=True)
        self.assertIn('BEGIN SSH SIGNATURE', release.git('cat-file', '-p', 'r0'))
        self.assertEqual(release.release_notes('r0', self.sha), NOTES.strip())

    def test_retry_preserves_existing_release(self):
        with patch.object(release, 'api', return_value=(200, self.existing)) as api:
            self.publish()
        self.assertEqual(api.call_count, 1)

    def test_draft_is_not_published(self):
        with patch.object(release, 'api', return_value=(200, dict(self.existing, draft=True))) as api:
            with self.assertRaisesRegex(ValueError, 'draft'):
                self.publish()
        self.assertEqual(api.call_count, 1)

    def test_concurrent_creation(self):
        with patch.object(release, 'api', side_effect=[(404, None), (422, None), (200, self.existing)]):
            self.assertEqual(self.publish(), self.existing['html_url'])

    def test_create_errors_are_not_success(self):
        for responses in [[(404, None), (404, None)],
                          [(404, None), (422, None), (404, None)],
                          [(422, None)]]:
            with self.subTest(responses=responses), patch.object(release, 'api', side_effect=responses):
                with self.assertRaisesRegex(ValueError, 'HTTP'):
                    self.publish()

    def test_reject_aliases_semver_and_invalid_primary_tags(self):
        for tag in ['18-r0', '18.6-r0', '1.2.3', 'r01', 'r00', 'r-1', 'r1\n']:
            with self.subTest(tag=tag), patch.object(release, 'api') as api:
                with self.assertRaisesRegex(ValueError, 'Only primary'):
                    release.publish('wodby/test', tag, self.sha)
                api.assert_not_called()

    def test_reject_lightweight_tag(self):
        release.git('tag', '-d', 'r0')
        release.git('tag', 'r0')
        with self.assertRaisesRegex(ValueError, 'annotated'):
            self.publish()

    def test_reject_wrong_commit(self):
        with self.assertRaisesRegex(ValueError, 'workflow commit'):
            release.publish('wodby/test', 'r0', '0' * 40)

    def test_reject_wrong_release_format(self):
        Path('.image-release-format').write_text('semver\n')
        release.git('commit', '-am', 'Fixture format')
        self.sha = release.git('rev-parse', 'HEAD')
        self.tag()
        with self.assertRaisesRegex(ValueError, 'does not use'):
            self.publish()

    def test_reject_empty_notes(self):
        self.tag(notes='')
        with self.assertRaisesRegex(ValueError, 'nonempty'):
            self.publish()

    def test_reject_remote_tag_replacement(self):
        release.git('tag', '-fa', 'r0', '-m', 'Different annotation')
        with self.assertRaisesRegex(ValueError, 'missing or changed'):
            self.publish()

    def test_reject_missing_remote_tag(self):
        release.git('push', 'origin', ':refs/tags/r0')
        with self.assertRaises(subprocess.CalledProcessError):
            self.publish()

    def test_reject_wrong_repository(self):
        with self.assertRaisesRegex(ValueError, 'Wodby'):
            release.publish('../test', 'r0', self.sha)


class ApiTests(unittest.TestCase):
    def test_auth_and_network_errors_fail_closed(self):
        with patch.dict(os.environ, {'GH_TOKEN': 'fixture'}):
            for status in [401, 403, 429, 500]:
                error = HTTPError('https://example.invalid', status, 'failure', {}, io.BytesIO())
                with patch.object(release, 'urlopen', side_effect=error):
                    with self.assertRaisesRegex(ValueError, str(status)):
                        release.api('GET', 'repos/wodby/test/releases/tags/r0')

    def test_missing_token_fails(self):
        with patch.dict(os.environ, {}, clear=True):
            with self.assertRaisesRegex(ValueError, 'GH_TOKEN'):
                release.api('GET', 'repos/wodby/test/releases/tags/r0')

    def test_api_request_body(self):
        response = io.BytesIO(b'{"tag_name":"r0"}')
        response.status = 201
        with patch.dict(os.environ, {'GH_TOKEN': 'fixture'}), \
                patch.object(release, 'urlopen', return_value=response) as urlopen:
            self.assertEqual(release.api('POST', 'repos/wodby/test/releases', {'name': 'r0'}),
                             (201, {'tag_name': 'r0'}))
        request = urlopen.call_args.args[0]
        self.assertEqual(request.full_url, 'https://api.github.com/repos/wodby/test/releases')
        self.assertEqual(json.loads(request.data), {'name': 'r0'})
        self.assertEqual(request.headers['Authorization'], 'Bearer fixture')

    def test_expected_error_statuses(self):
        with patch.dict(os.environ, {'GH_TOKEN': 'fixture'}):
            for status in [404, 422]:
                error = HTTPError('https://example.invalid', status, 'failure', {}, io.BytesIO())
                with patch.object(release, 'urlopen', side_effect=error):
                    self.assertEqual(release.api('GET', 'repos/wodby/test/releases/tags/r0'),
                                     (status, None))


class ActionTests(unittest.TestCase):
    def test_release_runs_after_alias_publication(self):
        root = Path(__file__).resolve().parents[1]
        action = yaml.safe_load((root / '.github/actions/image-revision-aliases/action.yml').read_text())
        steps = action['runs']['steps']
        self.assertIn('image_revision_aliases.py', steps[-2]['run'])
        self.assertIn('image_release.py', steps[-1]['run'])
        self.assertNotIn('if', steps[-1])
        self.assertNotIn('continue-on-error', steps[-2])
        self.assertEqual(steps[-1]['env']['GH_TOKEN'], '${{ github.token }}')

    def test_direct_publisher_uses_the_same_release_step(self):
        root = Path(__file__).resolve().parents[1] / '.github/actions'
        alias = yaml.safe_load((root / 'image-revision-aliases/action.yml').read_text())
        direct = yaml.safe_load((root / 'image-release/action.yml').read_text())
        self.assertEqual(alias['runs']['steps'][-1], direct['runs']['steps'][-1])
        self.assertEqual(direct['runs']['steps'][0]['with'],
                         {'ref': '${{ github.ref }}', 'fetch-depth': 0})


if __name__ == '__main__':
    unittest.main()
