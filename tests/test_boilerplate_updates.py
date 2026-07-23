import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CONFIG_PATH = ROOT / "boilerplates.json"
WORKFLOW_PATH = ROOT / ".github" / "workflows" / "workflow.yml"

EXPECTED_BOILERPLATES = {
    "django-boilerplate",
    "expressjs-boilerplate",
    "fastapi-boilerplate",
    "flask-boilerplate",
    "go-boilerplate",
    "nextjs-boilerplate",
    "php-package-boilerplate",
    "python-boilerplate",
    "rails-boilerplate",
    "react-boilerplate",
    "ruby-boilerplate",
}

EXPECTED_DEPENDENCY_FILES = {
    "bundler": ["Gemfile.lock"],
    "composer": ["composer.lock"],
    "go": ["go.mod", "go.sum"],
    "npm": ["package-lock.json"],
    "uv": ["uv.lock"],
}

EXPECTED_PROFILES = {
    "django",
    "expressjs",
    "go",
    "npm-build",
    "phpunit",
    "pytest",
    "python",
    "rails",
    "ruby",
}


class BoilerplateConfigTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.config = json.loads(CONFIG_PATH.read_text())
        cls.entries = cls.config["boilerplates"]

    def test_inventory_is_complete_and_unique(self):
        names = [entry["name"] for entry in self.entries]

        self.assertEqual(self.config["version"], 1)
        self.assertEqual(len(names), len(set(names)))
        self.assertEqual(set(names), EXPECTED_BOILERPLATES)

    def test_entries_use_supported_profiles_and_dependency_files(self):
        for entry in self.entries:
            with self.subTest(boilerplate=entry["name"]):
                self.assertEqual(entry["repo"], f"wodby/{entry['name']}")
                self.assertIn(entry["ecosystem"], EXPECTED_DEPENDENCY_FILES)
                self.assertIn(entry["profile"], EXPECTED_PROFILES)
                self.assertEqual(
                    entry["allowed_changes"],
                    EXPECTED_DEPENDENCY_FILES[entry["ecosystem"]],
                )
                self.assertTrue(entry["update_image"].startswith("wodby/"))
                self.assertGreaterEqual(len(entry["validation_images"]), 2)

    def test_workflow_matrix_comes_from_inventory(self):
        workflow = WORKFLOW_PATH.read_text()

        self.assertIn("[.boilerplates[].name]", workflow)
        self.assertIn(
            "fromJSON(needs.checks.outputs.boilerplates)",
            workflow,
        )


class AllowedChangesTest(unittest.TestCase):
    def run_check(self, repo: Path, allowed: list[str]) -> subprocess.CompletedProcess:
        allowed_json = json.dumps(allowed)
        script = (
            f'. "{ROOT / "update.sh"}"; '
            f'_assert_only_allowed_boilerplate_changes "{repo}" \'{allowed_json}\''
        )
        return subprocess.run(
            ["bash", "-c", script],
            capture_output=True,
            text=True,
            check=False,
        )

    def make_repo(self) -> Path:
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir)
        subprocess.run(["git", "init", "-q", str(temp_dir)], check=True)
        subprocess.run(
            ["git", "-C", str(temp_dir), "config", "user.email", "test@example.com"],
            check=True,
        )
        subprocess.run(
            ["git", "-C", str(temp_dir), "config", "user.name", "Test"],
            check=True,
        )
        subprocess.run(
            ["git", "-C", str(temp_dir), "config", "commit.gpgsign", "false"],
            check=True,
        )
        (temp_dir / "uv.lock").write_text("old\n")
        (temp_dir / "pyproject.toml").write_text("[project]\n")
        subprocess.run(["git", "-C", str(temp_dir), "add", "."], check=True)
        subprocess.run(["git", "-C", str(temp_dir), "commit", "-qm", "Initial"], check=True)
        return temp_dir

    def test_allows_configured_dependency_file(self):
        repo = self.make_repo()
        (repo / "uv.lock").write_text("new\n")

        result = self.run_check(repo, ["uv.lock"])

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_manifest_change(self):
        repo = self.make_repo()
        (repo / "pyproject.toml").write_text("[project]\nname = 'changed'\n")

        result = self.run_check(repo, ["uv.lock"])

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unexpected file", result.stderr)


if __name__ == "__main__":
    unittest.main()
