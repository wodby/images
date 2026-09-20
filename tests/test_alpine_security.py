"""Security revisions require package evidence, complete inputs and verified fixes."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('security', Path(__file__).parents[1] / 'scripts/alpine_security.py')
security = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(security)


def sbom(version='1.0-r0', name='openssl', distro='3.24.2'):
    return {'distro': {'id': 'alpine', 'versionID': distro},
            'artifacts': [{'name': name, 'version': version, 'type': 'apk'}]}


def scan(*cves, name='openssl'):
    return {'matches': [{'artifact': {'type': 'apk', 'name': name},
                         'vulnerability': {'id': cve}} for cve in cves]}


def compare(a, b):
    return '=' if a == b else ('>' if a > b else '<')


class SecurityTests(unittest.TestCase):
    def fixes(self, old=None, new=None, before=None, after=None):
        return security.fixed_packages(old or sbom(), new or sbom('1.0-r1'),
                                       before if before is not None else scan('CVE-2026-1234'),
                                       after if after is not None else scan(), compare)

    def test_security_upgrade_has_package_versions_and_cves(self):
        self.assertEqual(self.fixes(), [{'package': 'openssl', 'from': '1.0-r0',
                                        'to': '1.0-r1', 'cves': ['CVE-2026-1234']}])

    def test_digest_or_database_change_without_package_upgrade_does_not_release(self):
        self.assertEqual(self.fixes(new=sbom()), [])

    def test_nonsecurity_package_upgrade_does_not_release(self):
        self.assertEqual(self.fixes(before=scan()), [])

    def test_newly_discovered_or_unfixed_cve_does_not_release(self):
        self.assertEqual(self.fixes(after=scan('CVE-2026-1234', 'CVE-2026-5678')), [])

    def test_removed_or_downgraded_package_is_not_an_upgrade(self):
        self.assertEqual(self.fixes(new=sbom(name='curl')), [])
        self.assertEqual(self.fixes(new=sbom('0.9-r0')), [])

    def test_distribution_version_changes_use_existing_release_path(self):
        with self.assertRaisesRegex(ValueError, 'Distribution versions differ'):
            self.fixes(new=sbom('1.0-r1', distro='3.24.3'))

    def test_empty_or_invalid_inventory_cannot_look_fixed(self):
        for bad in ({}, {'distro': {'id': 'alpine'}, 'artifacts': []}):
            with self.assertRaises(ValueError):
                self.fixes(new=bad or {'unexpected': True})
        with self.assertRaisesRegex(ValueError, 'Missing Grype'):
            self.fixes(after={})

    def test_ignored_vulnerabilities_still_count(self):
        after = {'matches': [], 'ignoredMatches': scan('CVE-2026-1234')['matches']}
        self.assertEqual(self.fixes(after=after), [])

    def test_release_notes_group_architectures_and_keep_variant_scope(self):
        fixes = [{**self.fixes()[0], 'tag': '3.24-dev', 'arch': arch} for arch in security.ARCHES]
        notes = security.release_notes(fixes)
        self.assertIn('Alpine 3.24-dev (amd64, arm64): openssl 1.0-r0 -> 1.0-r1; fixes CVE-2026-1234', notes)
        self.assertEqual(notes.count('CVE-2026-1234'), 1)
        self.assertNotIn('sha256:', notes)

    def receipt(self):
        return {'schema': 1, 'release': 'r1',
                'targets': [{'tag': '3.24-dev', 'arch': 'arm64'}],
                'fixes': [{**self.fixes()[0], 'tag': '3.24-dev', 'arch': 'arm64'}]}

    def test_release_build_accepts_same_or_newer_fixed_package(self):
        for version in ('1.0-r1', '1.0-r2'):
            security.verify(self.receipt(), 'r1', '3.24-dev', 'arm64', sbom(version), scan(), compare)

    def test_release_build_rejects_missing_package_or_remaining_cve(self):
        for inventory, findings in [(sbom(), scan()), (sbom(name='curl'), scan()),
                                    (sbom('1.0-r1'), scan('CVE-2026-1234'))]:
            with self.assertRaises(ValueError):
                security.verify(self.receipt(), 'r1', '3.24-dev', 'arm64', inventory, findings, compare)

    def test_receipt_is_scoped_to_exact_release_and_matrix(self):
        security.verify(self.receipt(), 'r2', '', '', {}, {})
        with self.assertRaisesRegex(ValueError, 'matrix differs'):
            security.verify(self.receipt(), 'r1', '3.24', 'arm64', sbom(), scan(), compare)

    def test_scanner_uses_explicit_yaml_config_without_repository_ignores(self):
        calls = []
        def command(*args, **kwargs):
            calls.append(args)
            if args[0].endswith('/syft'):
                return json.dumps(sbom())
            config = Path(args[args.index('--config') + 1])
            self.assertEqual(config.suffix, '.yaml')
            self.assertEqual(config.read_text(), 'ignore: []\n')
            return json.dumps(scan())
        with patch.object(security, 'run', side_effect=command):
            security.Scanner('/tmp/security-tools').scan('registry:wodby/alpine@sha256:' + '1' * 64, 'arm64')
        self.assertIn('linux/arm64', calls[0])
        self.assertIn('--by-cve', calls[1])

    def test_scanner_disables_db_updates_and_uses_one_snapshot(self):
        scanner = security.Scanner('/tmp/security-tools')
        self.assertEqual(scanner.env['GRYPE_DB_AUTO_UPDATE'], 'false')
        self.assertEqual(scanner.env['GRYPE_DB_CACHE_DIR'], str(Path('/tmp/security-tools/db').resolve()))


class PlanTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        self.git('init', '-q')
        self.git('config', 'user.name', 'Test')
        self.git('config', 'user.email', 'test@example.invalid')
        self.git('config', 'commit.gpgsign', 'false')
        self.git('config', 'tag.gpgsign', 'false')
        (self.repo / '.github/workflows').mkdir(parents=True)
        (self.repo / '.github/workflows/workflow.yml').write_text("env:\n  ALPINE324: '3.24.2'\n")
        (self.repo / '.image-revision-aliases.json').write_text(json.dumps({
            'schema': 1, 'image': 'wodby/alpine', 'versions': [
                {'version': {'env': 'ALPINE324'}, 'variants': [
                    {'short': ['{minor}', '{major}']}, {'short': ['{minor}-dev']}]}]}))
        self.git('add', '.')
        self.git('commit', '-qm', 'Initial fixture')
        self.git('tag', '-am', 'First revision', 'r0')
        self.head = self.git('rev-parse', 'HEAD').strip()
        self.old = sbom(), scan('CVE-2026-1234')
        self.new = sbom('1.0-r1'), scan()
        self.scans = []
        self.old_ref = 'wodby/alpine@sha256:' + '1' * 64
        self.new_ref = 'wodby/alpine@sha256:' + '2' * 64

    def git(self, *args):
        return subprocess.check_output(['git', *args], cwd=self.repo, text=True, stderr=subprocess.DEVNULL)

    def manifests(self, image):
        ref = self.old_ref if image.endswith('-r0') else self.new_ref
        return {arch: ref for arch in security.ARCHES}

    def scan(self, image, arch):
        self.scans.append((image, arch))
        return self.old if image.endswith('1' * 64) else self.new

    def plan(self):
        with patch.object(security, 'manifests', side_effect=self.manifests), \
             patch.object(security, 'source_commit', return_value=self.head), \
             patch.object(security, 'version_compare', side_effect=compare):
            # The default comparator is bound when the function is declared.
            original = security.fixed_packages
            with patch.object(security, 'fixed_packages', side_effect=lambda *a: original(*a, compare=compare)):
                return security.plan(self.repo, self, 'r1')

    def test_all_architectures_and_variants_share_one_release(self):
        result = self.plan()
        self.assertEqual(result['release'], 'r1')
        self.assertEqual(len(result['targets']), 4)
        self.assertEqual(len(result['fixes']), 4)
        self.assertEqual(len(self.scans), 8)
        self.assertTrue(all('@sha256:' in ref for ref, _ in self.scans))
        self.assertEqual(result['source_commit'], self.head)

    def test_only_one_architecture_fix_is_sufficient(self):
        scan_image = self.scan
        self.scan = lambda image, arch: scan_image(image, arch) if arch == 'arm64' else self.old
        result = self.plan()
        self.assertEqual({f['arch'] for f in result['fixes']}, {'arm64'})

    def test_no_fix_produces_no_release(self):
        self.new = self.old
        self.assertNotIn('release', self.plan())

    def test_stale_mutable_images_defer_before_any_scan(self):
        with patch.object(security, 'manifests', side_effect=self.manifests), \
             patch.object(security, 'source_commit', return_value='older-commit'):
            result = security.plan(self.repo, self, 'r1')
        self.assertIn('Waiting', result['reason'])
        self.assertEqual(self.scans, [])

    def test_missing_baseline_or_architecture_fails_before_release(self):
        with patch.object(security, 'manifests', side_effect=ValueError('Missing published architecture')):
            with self.assertRaisesRegex(ValueError, 'Missing published'):
                security.plan(self.repo, self, 'r1')

    def test_incomplete_latest_release_defers_security_but_allows_other_updates(self):
        with patch.object(security, 'manifests', side_effect=security.PendingImage('Waiting for published image')):
            self.assertNotIn('release', security.plan(self.repo, self, 'r1'))
        self.assertEqual(self.scans, [])

    def test_scanner_failure_does_not_produce_release(self):
        self.scan = lambda *_: (_ for _ in ()).throw(ValueError('scanner unavailable'))
        with self.assertRaisesRegex(ValueError, 'scanner unavailable'):
            self.plan()

    def test_pending_release_cannot_allocate_another_revision(self):
        self.git('tag', '-am', 'Reserved release', 'r1')
        with self.assertRaisesRegex(ValueError, 'reservation changed'):
            self.plan()


if __name__ == '__main__':
    unittest.main()
