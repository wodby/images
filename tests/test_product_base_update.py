"""Exercise product updates using local Git remotes and fixture registry responses."""

import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
import product_base_update as updater
import image_release as release
import base_images

DIGEST = 'sha256:' + 'a' * 64
NEW_DIGEST = 'sha256:' + 'b' * 64


class ProductUpdateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        old = Path.cwd()
        self.addCleanup(os.chdir, old)
        root = Path(self.temp.name)
        checkout = root / 'checkout'
        checkout.mkdir()
        os.chdir(checkout)
        updater.git('init', '-q', '-b', 'main')
        for key, value in [('user.name', 'Test'), ('user.email', 'test@example.invalid'),
                           ('commit.gpgsign', 'false'), ('tag.gpgsign', 'false')]:
            updater.git('config', key, value)
        Path('.image-release-format').write_text('semver\n')
        Path('base-images.mk').write_text(
            'BASE_IMAGE_REPOSITORY := wodby/node\nBASE_IMAGE_VERSION_SUFFIX :=\n'
            'BASE_IMAGE_VERSION := 26\nBASE_IMAGE_REVISION := r5\n'
            f'BASE_IMAGE_DIGEST_26 := {DIGEST}\nBASE_IMAGE_DIGEST_26-r5 := {DIGEST}\n')
        updater.git('add', '.')
        updater.git('commit', '-qm', 'Fixture')
        updater.git('tag', '-am', 'Initial product release', '1.2.0')
        self.remote = str(root / 'origin.git')
        updater.git('init', '--bare', '-q', self.remote)
        updater.git('remote', 'add', 'origin', self.remote)
        updater.git('push', '-u', 'origin', 'main', '--tags')
        self.initial = updater.git('rev-parse', 'HEAD')
        self.original = Path('base-images.mk').read_text()
        self.parent = self.enterContext(patch.object(updater, 'latest_parent', return_value='r6'))
        self.notes = self.enterContext(patch.object(updater, 'parent_notes', return_value='Update Node packages.'))
        # BaseImages binds its resolver default at definition time, so intercept
        # the HTTP boundary rather than replacing the helper's function name.
        response = io.BytesIO(json.dumps({'digest': NEW_DIGEST}).encode())
        self.registry = self.enterContext(patch.object(base_images, 'urlopen', return_value=response))

    def prepare(self, publish=True):
        return updater.prepare('main', publish)

    def test_patch_publication_and_no_duplicate_or_rollback(self):
        self.assertEqual(self.prepare(), '1.2.1')
        self.assertEqual(updater.git('--git-dir=' + self.remote, 'rev-parse', '1.2.1^{commit}'),
                         updater.git('rev-parse', 'HEAD'))
        self.assertEqual(updater.git('cat-file', '-t', '1.2.1'), 'tag')
        self.assertIn('BASE_IMAGE_REVISION := r6', Path('base-images.mk').read_text())
        self.assertIn(f'BASE_IMAGE_DIGEST_26-r6 := {NEW_DIGEST}', Path('base-images.mk').read_text())
        self.assertIn('Update Node packages.', updater.git('for-each-ref', '--format=%(contents)', 'refs/tags/1.2.1'))
        for revision in ['r6', 'r5']:
            self.parent.return_value = revision
            self.assertEqual(self.prepare(), '1.2.1')
            self.assertEqual(sorted(updater.git('tag', '--list').splitlines()), ['1.2.0', '1.2.1'])
        self.assertEqual(updater.git('status', '--porcelain'), '')

    def test_preview_does_not_write_commit_tag_or_push(self):
        self.assertEqual(self.prepare(False), '')
        self.assertEqual(Path('base-images.mk').read_text(), self.original)
        self.assertEqual(updater.git('rev-parse', 'HEAD'), self.initial)
        self.assertEqual(updater.git('tag', '--list'), '1.2.0')

    def test_untagged_changes_do_not_get_released_without_parent_update(self):
        self.parent.return_value = 'r5'
        updater.git('commit', '--allow-empty', '-qm', 'Documentation')
        updater.git('push', 'origin', 'main')
        self.assertEqual(self.prepare(), '')

    def test_failures_cannot_advance_remote_or_consume_release(self):
        for dependency in [self.parent, self.notes, self.registry]:
            with self.subTest(dependency=dependency):
                dependency.side_effect = ValueError('Lookup failed')
                with self.assertRaises(ValueError):
                    self.prepare()
                dependency.side_effect = None
                self.assertEqual(updater.git('rev-parse', 'HEAD'), self.initial)
                self.assertEqual(updater.git('status', '--porcelain'), '')
                self.assertEqual(updater.git('tag', '--list'), '1.2.0')

    def test_atomic_push_rejection_does_not_publish_pin_commit(self):
        hook = Path(self.remote) / 'hooks/update'
        hook.write_text('#!/bin/sh\ncase "$1" in refs/tags/*) exit 1 ;; esac\n')
        hook.chmod(0o755)
        with self.assertRaises(subprocess.CalledProcessError):
            self.prepare()
        self.assertEqual(updater.git('--git-dir=' + self.remote, 'rev-parse', 'main'), self.initial)
        self.assertEqual(updater.git('--git-dir=' + self.remote, 'tag', '--list'), '1.2.0')

    def test_dirty_and_nondefault_checkouts_are_rejected(self):
        Path('unrelated').write_text('preserve')
        with self.assertRaisesRegex(ValueError, 'clean'):
            self.prepare()
        Path('unrelated').unlink()
        with self.assertRaisesRegex(ValueError, 'default branch'):
            updater.prepare('master', True)
        updater.git('commit', '--allow-empty', '-qm', 'Unpushed')
        with self.assertRaisesRegex(ValueError, 'fetched'):
            self.prepare()

    def test_dispatch_and_retry_after_push(self):
        self.prepare()
        with patch.object(updater, 'api', side_effect=[(404, None), (200, {'workflow_runs': []}), (204, None)]) as api:
            updater.dispatch('wodby/example', 'build.yml', '1.2.1')
            self.assertEqual(api.call_args.args, ('POST', 'repos/wodby/example/actions/workflows/build.yml/dispatches', {'ref': '1.2.1'}))
        with patch.object(updater, 'api', side_effect=[(404, None), (200, {'workflow_runs': [
                {'head_branch': '1.2.1', 'status': 'in_progress'}]})]) as api:
            updater.dispatch('wodby/example', 'build.yml', '1.2.1')
            self.assertEqual(api.call_count, 2)
        with patch.object(updater, 'api', return_value=(200, {'draft': False, 'tag_name': '1.2.1'})) as api:
            updater.dispatch('wodby/example', 'build.yml', '1.2.1')
            self.assertEqual(api.call_count, 1)

    def test_semver_release_requires_matching_marker_and_annotated_tag(self):
        notes = release.release_notes('1.2.0', self.initial, 'semver')
        self.assertEqual(notes, 'Initial product release')
        with self.assertRaises(ValueError):
            release.release_notes('1.2.0', self.initial)
        with self.assertRaises(ValueError):
            release.release_notes('1.2.0-rc1', self.initial, 'semver')
        existing = {'tag_name': '1.2.0', 'draft': False, 'html_url': 'https://example.invalid/release'}
        with patch.object(release, 'api', side_effect=[(404, None), (201, existing)]) as api:
            release.publish('wodby/example', '1.2.0', self.initial, 'semver')
            self.assertEqual(api.call_args.args[2]['name'], '1.2.0')


class RegistryAndApiTests(unittest.TestCase):
    def test_registry_pagination_ignores_other_lines_and_variants(self):
        responses = [io.BytesIO(json.dumps(value).encode()) for value in [
            {'results': [{'name': '26-r6'}, {'name': '26-dev-r99'}, {'name': '28-r99'}], 'next': 'yes'},
            {'results': [{'name': '26-r10'}, {'name': '26-r01'}], 'next': None}]]
        with patch.object(updater, 'urlopen', side_effect=responses):
            self.assertEqual(updater.latest_parent('wodby/node', '26-'), 'r10')

    def test_parent_notes_require_annotation_and_strip_signature(self):
        with patch.object(updater, 'api', side_effect=[
                (200, {'object': {'type': 'tag', 'sha': 'a' * 40}}),
                (200, {'tag': '26-r6', 'message': 'Fix packages\n-----BEGIN SSH SIGNATURE-----\nfixture'})]):
            self.assertEqual(updater.parent_notes('wodby/node', '26-r6'), 'Fix packages')
        with patch.object(updater, 'api', return_value=(200, {'object': {'type': 'commit'}})):
            with self.assertRaisesRegex(ValueError, 'annotated'):
                updater.parent_notes('wodby/node', '26-r6')

    def test_dispatch_api_accepts_empty_204_response(self):
        response = io.BytesIO(b'')
        response.status = 204
        with patch.dict(os.environ, {'GH_TOKEN': 'fixture'}), patch.object(release, 'urlopen', return_value=response):
            self.assertEqual(release.api('POST', 'repos/wodby/example/actions/workflows/build.yml/dispatches', {'ref': '1.2.0'}), (204, None))
