#!/usr/bin/env python3
"""Exercise revision allocation and publication without contacting a registry."""

import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    'aliases', Path(__file__).resolve().parents[1] / 'scripts/image_revision_aliases.py')
aliases = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(aliases)
DIGEST = 'sha256:' + 'a' * 64
OTHER = 'sha256:' + 'b' * 64


class AliasTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.path = root / 'source'
        self.path.mkdir()
        self.repo = aliases.Repository(self.path)
        self.repo.git('init', '-q')
        self.repo.git('config', 'user.name', 'Release test')
        self.repo.git('config', 'user.email', 'test@example.invalid')
        self.repo.git('config', 'commit.gpgsign', 'false')
        self.repo.git('config', 'tag.gpgsign', 'false')
        self.repo.git('init', '--bare', '-q', str(root / 'origin'))
        self.repo.git('remote', 'add', 'origin', str(root / 'origin'))
        self.registry = {}
        self.writes = []
        self.config = {'schema': 1, 'image': 'wodby/mariadb', 'versions': [{
            'version': {'env': 'MARIADB114'}, 'variants': [
                {'short': ['{minor}', '{major}'], 'full': '{version}'},
                {'short': ['{minor}-dev', '{major}-dev'], 'full': '{version}-dev'}]}]}

    def release(self, tag, version='11.4.2'):
        """Create disposable Git fixtures, including non-ancestral releases."""
        path = self.path / aliases.WORKFLOW
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f"env:\n  MARIADB114: '{version}'\n")
        (self.path / aliases.CONFIG).write_text(json.dumps(self.config))
        self.repo.git('add', '.')
        self.repo.git('commit', '--allow-empty', '-qm', f'Fixture {tag}')
        self.repo.git('tag', '-a', tag, '-m', f'Fixture release {tag}')
        self.repo.read.cache_clear()
        return self.repo.plan(tag)

    def seed_sources(self, plan):
        for alias in plan['aliases']:
            self.registry[f'{plan["image"]}:{alias["source"]}'] = DIGEST

    def command(self, *args, **kwargs):
        """Keep Git real and replace only Docker's registry boundary."""
        if args[0] != 'docker':
            return self.real_command(*args, **kwargs)
        if args[3] == 'inspect':
            value = self.registry.get(args[4])
            return subprocess.CompletedProcess(args, 0 if value else 1,
                                               f'Digest: {value}\n' if value else '',
                                               '' if value else 'ERROR: manifest unknown')
        self.assertEqual(args[:5], ('docker', 'buildx', 'imagetools', 'create', '--prefer-index=false'))
        self.assertEqual(args[5], '--tag')
        self.registry[args[6]] = args[7].split('@')[1]
        self.writes.append(args[6])
        return subprocess.CompletedProcess(args, 0, '', '')

    def publish(self, plan):
        self.real_command = aliases.command
        with patch.object(aliases, 'command', side_effect=self.command):
            aliases.publish(self.repo, plan)

    def test_resets_only_for_complete_version(self):
        first = self.release('r1')
        self.release('r2')
        self.release('r3', '11.4.3')
        # A maintenance release need not descend from the current main branch.
        self.repo.git('checkout', '--detach', '-q', 'r1')
        later = self.release('r10')
        self.assertEqual([a['tag'] for a in first['aliases']], [
            '11-dev-r1', '11-r1', '11.4-dev-r1', '11.4-r1', '11.4.2-dev-r0', '11.4.2-r0'])
        self.assertIn('11.4.2-r2', [a['tag'] for a in later['aliases']])
        self.assertIn('11.4.3-r0', [a['tag'] for a in self.repo.plan('r3')['aliases']])
        # Finishing an older release after a newer one never changes its plan.
        self.assertEqual(self.repo.plan('r1'), first)

    def test_alias_tags_and_legacy_releases_do_not_allocate(self):
        plan = self.release('r1')
        for tag in ['11.4-r99', '11.4.2-r88', '4.83.3', 'r01', 'r0', 'rjunk']:
            self.repo.git('tag', '-a', tag, '-m', 'Unrelated fixture tag')
        self.assertEqual(plan, self.repo.plan('r1'))
        for tag in ['11.4-r99', 'r01', 'r0', '4.83.3']:
            with self.assertRaisesRegex(ValueError, 'Only primary'):
                self.repo.plan(tag)

    def test_releases_before_alias_opt_in_are_ignored(self):
        self.release('r1')
        self.repo.git('tag', '-d', 'r1')
        self.repo.git('rm', aliases.CONFIG)
        self.repo.git('commit', '-qm', 'Fixture before aliases')
        self.repo.git('tag', '-a', 'r1', '-m', 'Earlier primary release')
        plan = self.release('r2')
        self.assertIn('11.4.2-r0', [a['tag'] for a in plan['aliases']])

    def test_same_commit_new_primary_counts_as_rebuild(self):
        self.release('r1')
        self.repo.git('tag', '-a', 'r2', '-m', 'Rebuild fixture')
        self.assertIn('11.4.2-r1', [a['tag'] for a in self.repo.plan('r2')['aliases']])

    def test_publish_preserves_digest_and_annotates_all_aliases(self):
        plan = self.release('r1')
        self.seed_sources(plan)
        self.publish(plan)
        self.assertEqual(len(self.writes), 2)
        for alias in plan['aliases']:
            ref = 'refs/tags/' + alias['tag']
            self.assertEqual(self.repo.git('cat-file', '-t', ref).stdout.strip(), 'tag')
            self.assertEqual(self.repo.git('rev-parse', ref+'^{commit}').stdout.strip(), plan['commit'])
            self.assertIn(DIGEST, self.repo.git('for-each-ref', '--format=%(contents)', ref).stdout)
            self.assertIn(ref, self.repo.git('ls-remote', 'origin', ref).stdout)
        self.publish(self.repo.plan('r1'))
        self.assertEqual(len(self.writes), 2, 'Retry must not republish any manifest')

    def test_partial_docker_publication_resumes(self):
        plan = self.release('r1')
        self.seed_sources(plan)
        self.registry['wodby/mariadb:11.4.2-r0'] = DIGEST
        self.publish(plan)
        self.assertEqual(self.writes, ['wodby/mariadb:11.4.2-dev-r0'])

    def test_docker_collision_fails_before_any_write(self):
        plan = self.release('r1')
        self.seed_sources(plan)
        self.registry['wodby/mariadb:11.4.2-r0'] = OTHER
        with self.assertRaisesRegex(ValueError, 'overwrite Docker'):
            self.publish(plan)
        self.assertEqual(self.writes, [])
        self.assertEqual(self.repo.git('tag', '--list').stdout.strip(), 'r1')

    def test_git_collision_fails_before_any_registry_write(self):
        plan = self.release('r1')
        self.repo.git('tag', '11.4-r1')  # Lightweight tags are not our aliases.
        with self.assertRaisesRegex(ValueError, 'overwrite Git'):
            self.publish(plan)
        self.assertEqual(self.writes, [])

    def test_git_alias_on_wrong_commit_is_rejected(self):
        first = self.release('r1')
        self.release('r2', '11.4.3')
        self.repo.git('tag', '-a', '11.4-r1', '-m', 'Conflicting fixture')
        with self.assertRaisesRegex(ValueError, 'overwrite Git'):
            self.publish(first)

    def test_unavailable_source_fails_before_any_write(self):
        plan = self.release('r1')
        with self.assertRaisesRegex(ValueError, 'Cannot inspect'):
            self.publish(plan)
        self.assertEqual(self.writes, [])

    def test_inspection_error_is_not_treated_as_missing(self):
        result = subprocess.CompletedProcess([], 1, '', 'unauthorized: authentication required')
        with patch.object(aliases, 'command', return_value=result):
            with self.assertRaisesRegex(ValueError, 'Cannot inspect'):
                aliases.digest('wodby/mariadb:11.4.2-r0', missing_ok=True)

    def test_git_push_failure_can_resume(self):
        plan = self.release('r1')
        self.seed_sources(plan)
        original = self.repo.git
        def git(*args, **kwargs):
            if args[0] == 'push':
                raise ValueError('Simulated push interruption')
            return original(*args, **kwargs)
        with patch.object(self.repo, 'git', side_effect=git):
            with self.assertRaisesRegex(ValueError, 'interruption'):
                self.publish(plan)
        self.publish(self.repo.plan('r1'))
        self.assertEqual(len(self.writes), 2)

    def test_overlapping_full_and_short_names_are_rejected(self):
        self.config['versions'][0]['variants'][0]['full'] = '{minor}'
        with self.assertRaisesRegex(ValueError, 'namespaces overlap'):
            self.release('r1')

    def test_two_part_full_version_uses_major_source(self):
        self.config['versions'][0]['variants'] = [{'short': ['{major}'], 'full': '{version}'}]
        plan = self.release('r1', '17.11')
        self.assertEqual([a['tag'] for a in plan['aliases']], ['17-r1', '17.11-r0'])

    def test_wordpress_initial_version_is_normalized(self):
        self.config['versions'][0]['version']['pad_patch'] = True
        plan = self.release('r1', '7.2')
        self.assertIn('7.2.0-r0', [a['tag'] for a in plan['aliases']])
        self.assertIn('7.2-r1', [a['tag'] for a in plan['aliases']])

    def test_parent_is_resolved_from_pinned_release(self):
        workflow = {'env': {'BASE_IMAGE_STABILITY_TAG': '4.71.5'}}
        selector = {'repository': 'wodby/php', 'parent_env': 'PHP85'}
        with patch.object(self.repo, 'parent_workflow', return_value={'env': {'PHP85': '8.5.10'}}) as parent:
            self.assertEqual(self.repo.version('HEAD', selector, workflow), '8.5.10')
            parent.assert_called_once_with('wodby/php', '4.71.5')
        with self.assertRaisesRegex(ValueError, 'pinned'):
            self.repo.parent_workflow('wodby/php', 'master')


if __name__ == '__main__':
    unittest.main()
