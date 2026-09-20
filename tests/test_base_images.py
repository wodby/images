"""Exercise pin transitions and ensure failed lookups cannot advance build inputs."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("base_images", Path(__file__).parents[1] / "scripts/base_images.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
A = "sha256:" + "a" * 64
B = "sha256:" + "b" * 64


class PinTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / "base-images.mk"

    def write(self, pins, repository="php", suffix="-fpm-alpine"):
        self.path.write_text(
            f"BASE_IMAGE_REPOSITORY := {repository}\nBASE_IMAGE_VERSION_SUFFIX := {suffix}\n\n"
            + "".join(f"BASE_IMAGE_DIGEST_{tag} := {digest}\n" for tag, digest in pins.items())
            + '\nBASE_IMAGE = $(BASE_IMAGE_REPOSITORY):$(BASE_IMAGE_TAG)@$(or $(BASE_IMAGE_DIGEST_$(BASE_IMAGE_TAG)),$(error Missing pin))\n'
        )
        return module.BaseImages(self.path)

    def test_refresh_uses_exact_tags_and_is_idempotent(self):
        pins = self.write({"8.5.10-fpm-alpine": A, "8.4.25-fpm-alpine": B})
        seen = []
        def resolve(repo, tag):
            seen.append((repo, tag))
            return B
        changed = pins.update("refresh", resolver=resolve)
        self.assertEqual(seen, [("php", "8.5.10-fpm-alpine"), ("php", "8.4.25-fpm-alpine")])
        self.assertEqual(len(changed), 1)
        self.assertEqual(module.BaseImages(self.path).ref_for_line("8.5"), "php:8.5.10-fpm-alpine@" + B)
        before = self.path.stat().st_mtime_ns
        self.assertEqual(module.BaseImages(self.path).update("refresh", resolver=resolve), [])
        self.assertEqual(before, self.path.stat().st_mtime_ns)

    def test_failed_or_invalid_lookup_preserves_every_pin(self):
        for failure in [ValueError("upstream unavailable"), "not-a-digest"]:
            with self.subTest(failure=failure):
                pins = self.write({"8.5.10-fpm-alpine": A, "8.4.25-fpm-alpine": A})
                before = self.path.read_bytes()
                def resolve(repo, tag):
                    if tag.startswith("8.5"):
                        return B
                    if isinstance(failure, Exception):
                        raise failure
                    return failure
                with self.assertRaises(ValueError):
                    pins.update("refresh", resolver=resolve)
                self.assertEqual(before, self.path.read_bytes())
                self.assertFalse(list(self.path.parent.glob(".base-images-*")))

    def test_version_change_keeps_the_build_variant(self):
        pins = self.write({"8.5.10-fpm-alpine": A, "8.4.25-fpm-alpine": A})
        seen = []
        def resolve(repo, tag):
            seen.append(tag)
            return B
        pins.update("version", "8.5.10", "8.5.11", resolve)
        current = module.BaseImages(self.path)
        self.assertEqual(seen, ["8.5.11-fpm-alpine"])
        self.assertEqual(current.pins, {"8.5.11-fpm-alpine": B, "8.4.25-fpm-alpine": A})
        with self.assertRaises(ValueError):
            current.update("version", "8.5.10", "8.5.12", resolve)

    def test_stability_update_covers_all_variants_and_lines(self):
        tags = ["8.5", "8.5-dev", "8.5-dev-macos", "8.4"]
        initial = {tag: A for tag in tags}
        initial.update({tag + "-4.70.0": A for tag in tags})
        pins = self.write(initial, "wodby/php", "")
        seen = []
        def resolve(repo, tag):
            seen.append(tag)
            return B
        pins.update("stability", new="4.71.0", resolver=resolve)
        current = module.BaseImages(self.path)
        self.assertEqual(set(seen), {tag + "-4.71.0" for tag in tags})
        self.assertEqual(current.ref_for_line("8.5", "4.71.0"), "wodby/php:8.5-4.71.0@" + B)
        self.assertTrue(all(current.pins[tag] == A for tag in tags))
        self.assertFalse(any(tag.endswith("4.70.0") for tag in current.pins))

    def test_incomplete_stability_publication_does_not_change_pins(self):
        pins = self.write({"8.5": A, "8.5-dev": A}, "wodby/php", "")
        before = self.path.read_bytes()
        def resolve(repo, tag):
            if "-dev-" in tag:
                raise ValueError("variant not published")
            return B
        with self.assertRaises(ValueError):
            pins.update("stability", new="4.71.0", resolver=resolve)
        self.assertEqual(before, self.path.read_bytes())

    def test_make_consumes_the_pin_and_rejects_missing_versions(self):
        self.write({"8.5.10-fpm-alpine": A})
        makefile = self.path.parent / "Makefile"
        makefile.write_text('include base-images.mk\nprint:\n\t@echo "$(BASE_IMAGE)"\n')
        result = subprocess.run(["make", "-s", "print", "BASE_IMAGE_TAG=8.5.10-fpm-alpine"], cwd=self.path.parent, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "php:8.5.10-fpm-alpine@" + A)
        result = subprocess.run(["make", "-s", "print", "BASE_IMAGE_TAG=8.5.99-fpm-alpine"], cwd=self.path.parent, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Missing pin", result.stderr)

    def test_rejects_duplicate_and_malformed_pins(self):
        self.write({"8.5.10-fpm-alpine": A})
        with self.path.open("a") as stream:
            stream.write(f"BASE_IMAGE_DIGEST_8.5.10-fpm-alpine := {A}\n")
        with self.assertRaises(ValueError):
            module.BaseImages(self.path)
        self.path.write_text(self.path.read_text().replace(A, "sha256:bad"))
        with self.assertRaises(ValueError):
            module.BaseImages(self.path)

    def test_builder_refresh_and_runtime_refresh_are_atomic(self):
        self.write({"8.4.11": A}, "mysql", "")
        with self.path.open("a") as stream:
            stream.write(f"BUILD_IMAGE_GOSU := golang:alpine@{A}\n")
        pins = module.BaseImages(self.path)
        before = self.path.read_bytes()
        def failing(repo, tag):
            if repo == "golang":
                raise ValueError("builder unavailable")
            return B
        with self.assertRaises(ValueError):
            pins.update("refresh", resolver=failing)
        self.assertEqual(before, self.path.read_bytes())
        changes = pins.update("refresh", resolver=lambda repo, tag: B)
        self.assertEqual(len(changes), 2)
        current = module.BaseImages(self.path)
        self.assertEqual(current.builders["BUILD_IMAGE_GOSU"], ("golang", "alpine", B))
        self.assertEqual(current.pins["8.4.11"], B)

    def test_line_selection_has_exact_boundaries(self):
        pins = self.write({"8.5.10-fpm-alpine": A, "8.50.1-fpm-alpine": B})
        self.assertEqual(pins.ref_for_line("8.5"), "php:8.5.10-fpm-alpine@" + A)
        with self.assertRaises(ValueError):
            pins.ref_for_line("8.4")
        with self.assertRaises(ValueError):
            pins.ref_for_line("8")


if __name__ == "__main__":
    unittest.main()
