"""Regression cases from published image inventories and upstream fixed versions."""

import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    "check_brotli", Path(__file__).resolve().parents[1] / "scripts/check_brotli.py")
brotli = importlib.util.module_from_spec(spec)
spec.loader.exec_module(brotli)


class BrotliTests(unittest.TestCase):
    def test_published_affected_packages(self):
        for inventory in ("apk\t1.1.0-r2", "apk\t1.2.0-r0", "apk\t1.2.0-r1",
                          "dpkg\t1.1.0-2+b7", "dpkg\t1.0.9-2+b6",
                          "rpm\t1.0.9-10.el9_8"):
            with self.subTest(inventory=inventory):
                self.assertTrue(brotli.inspect_inventory(inventory))

    def test_all_fixed_upstream_release_lines(self):
        for version in ("1.0.10-r0", "1.1.1-r0", "1.2.1-r0", "1.3.0-r0"):
            with self.subTest(version=version):
                self.assertEqual([], brotli.inspect_inventory(f"apk\t{version}"))

    def test_vendor_backport_without_changed_upstream_version(self):
        for kind, version in (("dpkg", "1.0.9-2+deb12u1"),
                              ("dpkg", "1.1.0-2+deb13u1"),
                              ("rpm", "1.0.9-11.el9_8")):
            inventory = f"{kind}\t{version}\n{kind}-backport\tverified"
            self.assertEqual([], brotli.inspect_inventory(inventory))

    def test_fixed_system_package_does_not_clear_nix_copy(self):
        inventory = "apk\t1.2.1-r0\nnix\t/nix/store/hash-brotli-1.1.0-lib/lib/libbrotlidec.so.1"
        self.assertTrue(brotli.inspect_inventory(inventory))

    def test_fixed_nix_copy(self):
        inventory = "nix\t/nix/store/hash-brotli-1.1.1-lib/lib/libbrotlidec.so.1"
        self.assertEqual([], brotli.inspect_inventory(inventory))

    def test_unaccounted_curl_decoder(self):
        self.assertTrue(brotli.inspect_inventory("curl\tcurl 8.22 brotli/1.2.0"))
        self.assertEqual([], brotli.inspect_inventory("curl\tcurl 8.22 zlib/1.3.1"))

    def test_patched_runtimes_do_not_clear_system_package(self):
        self.assertTrue(brotli.inspect_inventory("apk\t1.2.0-r1\nnode\t24.22.1\nbun\t1.4.4"))

    def test_curl_must_use_the_checked_library(self):
        self.assertTrue(brotli.inspect_inventory("apk\t1.2.1-r0\ncurl\tcurl brotli/1.2.0"))
        self.assertEqual([], brotli.inspect_inventory(
            "dpkg\t1.1.0-2+deb13u1\ndpkg-backport\tverified\ncurl\tcurl brotli/1.1.0"))

    def test_runtime_security_releases(self):
        for version in ("22.23.4", "24.22.1", "26.12.1"):
            self.assertEqual([], brotli.inspect_inventory(f"node\t{version}", check_node=True))
        for version in ("22.23.3", "24.22.0", "26.12.0", "20.19.0"):
            self.assertTrue(brotli.inspect_inventory(f"node\t{version}", check_node=True))
        self.assertTrue(brotli.inspect_inventory("bun\t1.4.3", check_bun=True))
        self.assertEqual([], brotli.inspect_inventory("bun\t1.4.4", check_bun=True))

    def test_missing_requested_runtime(self):
        self.assertTrue(brotli.inspect_inventory("apk\t1.2.1-r0", check_node=True))
        self.assertTrue(brotli.inspect_inventory("apk\t1.2.1-r0", check_bun=True))

    def test_unknown_inventory_fails_closed(self):
        with self.assertRaises(ValueError):
            brotli.inspect_inventory("")
        with self.assertRaises(ValueError):
            brotli.inspect_inventory("dpkg\tnot-a-version")
        with self.assertRaises(ValueError):
            brotli.inspect_inventory("truncated record")


if __name__ == "__main__":
    unittest.main()
