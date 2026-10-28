"""Check the identity on real updater commits and annotated release tags."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]


class GitIdentityTests(unittest.TestCase):
    def check_identity(self, configured):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            environment = dict(os.environ)
            for key in ('WODBOT_GIT_NAME', 'WODBOT_GIT_EMAIL'):
                environment.pop(key, None)
            environment.update({
                'GIT_CONFIG_GLOBAL': str(path / 'global.gitconfig'),
                'GIT_CONFIG_NOSYSTEM': '1',
                'GIT_AUTHOR_NAME': 'Inherited author',
                'GIT_AUTHOR_EMAIL': 'author@example.invalid',
                'GIT_COMMITTER_NAME': 'Inherited committer',
                'GIT_COMMITTER_EMAIL': 'committer@example.invalid',
                'UPDATER_ROOT': str(ROOT),
                'IMAGES_UPDATE_PUSH': '1',
                **configured,
            })

            def git(*args):
                return subprocess.check_output(
                    ['git', *args], cwd=path, env=environment, text=True).strip()

            git('init', '-q')
            git('config', '--global', 'user.name', 'Runner')
            git('config', '--global', 'user.email', 'runner@example.invalid')
            git('config', '--local', 'user.name', 'Previous checkout')
            git('config', '--local', 'user.email', 'checkout@example.invalid')
            git('config', 'commit.gpgsign', 'false')
            git('config', 'tag.gpgsign', 'false')
            git('commit', '--allow-empty', '-qm', 'Initial fixture')
            git('tag', '-am', 'Initial fixture release', '1.0.0')
            (path / 'fixture').write_text('updated\n')
            subprocess.run(['bash', '-euc', '''
                source "$UPDATER_ROOT/update.sh"
                _git_push() { :; }
                _git_commit . 'Update fixture'
                _release_tag 'Release the fixture update' ''
            '''], cwd=path, env=environment, check=True, capture_output=True)
            name = configured.get('WODBOT_GIT_NAME', 'Wodby Robot')
            email = configured.get('WODBOT_GIT_EMAIL', 'robot@wodby.com')
            self.assertEqual(git('log', '-1', '--format=%an <%ae>|%cn <%ce>'),
                             f'{name} <{email}>|{name} <{email}>')
            self.assertEqual(git('for-each-ref', '--format=%(taggername) %(taggeremail)',
                                 'refs/tags/1.0.1'), f'{name} <{email}>')
            self.assertEqual(git('config', '--global', 'user.name'), 'Runner')
            self.assertEqual(git('config', '--global', 'user.email'), 'runner@example.invalid')

    def test_default_bot_overrides_inherited_config_and_environment(self):
        self.check_identity({})

    def test_configured_bot_overrides_inherited_config_and_environment(self):
        self.check_identity({'WODBOT_GIT_NAME': 'Configured Bot',
                             'WODBOT_GIT_EMAIL': 'configured@example.invalid'})

    def test_publishing_actions_use_shared_bot_identity(self):
        for name in ('product-base-update', 'image-revision-aliases'):
            with self.subTest(action=name):
                action = yaml.safe_load((ROOT / '.github/actions' / name / 'action.yml').read_text())
                scripts = '\n'.join(step.get('run', '') for step in action['runs']['steps'])
                self.assertIn('scripts/git_identity.sh', str(action))
                self.assertIn('configure_wodbot_git_identity', scripts)
                self.assertNotIn('git config user.', scripts)
