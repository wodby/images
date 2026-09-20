import argparse
import io
import json
import sys
import tempfile
import unittest
import urllib.error
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import image_update_report as report
import image_report_email as email


class GrypeReportTests(unittest.TestCase):
    def inspect(self, text):
        with patch.object(report, "fetch_grype_config", return_value=(".grype.yaml", text)):
            return report.inspect_grype_exceptions(("wodby/python", "HEAD"))

    def test_scoped_and_broad_rules(self):
        found, warnings = self.inspect('''ignore:
  - vulnerability: CVE-2026-82049
    package:
      name: python
      version: 3.13.15
      type: binary
  - package:
      name: example
      location: /opt/**
  - {}
''')
        self.assertEqual(warnings, [])
        self.assertEqual(len(found), 3)
        self.assertEqual(found[0]["rule"]["package"]["version"], "3.13.15")
        self.assertIn('"location": "/opt/**"', found[1]["message"])
        self.assertEqual(found[2]["rule"], {})
        self.assertIn("https://github.com/wodby/python/blob/HEAD/.grype.yaml", found[0]["message"])

    def test_empty_and_comment_only_configs(self):
        for text in ("", "# ignore:\n# - vulnerability: CVE-example", "ignore: []", "ignore: null", "log: {level: warn}"):
            with self.subTest(text=text):
                self.assertEqual(self.inspect(text), ([], []))

    def test_invalid_configs_warn(self):
        for text in ("ignore: [", "[]", "ignore: false", "ignore: example", "ignore: [example]", "!!python/object:example {}", "ignore: [{1: value, text: value}]"):
            with self.subTest(text=text):
                found, warnings = self.inspect(text)
                self.assertEqual(found, [])
                self.assertTrue(warnings)

    def test_missing_and_failed_fetches(self):
        with patch.object(report, "fetch_grype_config", return_value=None):
            self.assertEqual(report.inspect_grype_exceptions(("wodby/python", "HEAD")), ([], []))
        for error in (urllib.error.HTTPError("url", 403, "forbidden", {}, None), urllib.error.URLError("timeout")):
            with patch.object(report, "fetch_grype_config", side_effect=error):
                found, warnings = report.inspect_grype_exceptions(("wodby/python", "HEAD"))
                self.assertFalse(found)
                self.assertIn("Failed to inspect", warnings[0])

    def test_search_order_and_first_config_wins(self):
        missing = urllib.error.HTTPError("url", 404, "missing", {}, None)
        with patch.object(report.urllib.request, "urlopen", side_effect=[missing, io.BytesIO(b"ignore: []")]) as fetch:
            self.assertEqual(report.fetch_grype_config("wodby/python", "release/3"), (".grype.yml", "ignore: []"))
            self.assertEqual(fetch.call_count, 2)
            self.assertIn("release%2F3/.grype.yml", fetch.call_args.args[0].full_url)
        with patch.object(report.urllib.request, "urlopen", side_effect=missing) as fetch:
            self.assertIsNone(report.fetch_grype_config("wodby/python", "HEAD"))
            self.assertEqual(fetch.call_count, 4)

    def test_unique_repo_refs(self):
        items = [report.VersionItem("wodby/python", "python", "python", v, "test", ref)
                 for v, ref in (("3.13", "HEAD"), ("3.10", "HEAD"), ("3.13", "stable"))]
        with patch.object(report, "inspect_grype_exceptions", return_value=([], [])) as inspect:
            self.assertEqual(report.collect_grype_exceptions(items), ([], []))
            self.assertEqual(sorted(c.args[0] for c in inspect.call_args_list),
                             [("wodby/python", "HEAD"), ("wodby/python", "stable")])

    def test_report_and_email_pipeline(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            readme = root / "README.md"
            readme.write_text('''### Images based on official images (or forks)
| Image | Upstream | Versions |
| [wodby/python] | [python] | `3.13`, `3.10` |
''')
            args = argparse.Namespace(readme=str(readme), events_dir=str(root), eol_warning_days=90)
            config = 'ignore:\n  - vulnerability: CVE-example\n    package: {name: "<unsafe>&", version: 3.13.15}\n'
            with patch.object(report, "analyze_versions", return_value=([], [], [])), patch.object(report, "fetch_grype_config", return_value=(".grype.yaml", config)) as fetch:
                data = report.generate_report(args)
            fetch.assert_called_once_with("wodby/python", "HEAD")
            self.assertEqual(data["totals"]["grype_exceptions"], 1)
            self.assertEqual(data["totals"]["updated_repos"], 0)
            self.assertEqual(data["totals"]["update_events"], 0)
            markdown = report.render_markdown(data)
            self.assertIn("## Grype Exception Warnings", markdown)
            self.assertNotIn("No reportable", markdown)
            (root / "image-update-report.json").write_text(json.dumps(data))
            data = email.load_report(root)
            counts = email.event_counts(data, "success", "success")
            self.assertFalse(email.has_email_worthy_events(counts))
            context = dict(run_url="https://example.com/run", event="schedule", sha="abc", workflow_result="success", artifact_result="success")
            plain = email.build_body(data, counts, **context)
            html = email.build_html_body(data, counts, **context)
            for output in (plain, html):
                self.assertIn("Grype Exception Warnings", output)
                self.assertIn("CVE-example", output)
            self.assertNotIn("<unsafe>", html)
            self.assertIn("&lt;unsafe&gt;&amp;", html)
            for key in ("update_events", "workflow_failures", "artifact_failures"):
                self.assertTrue(email.has_email_worthy_events({**counts, key: 1}))

    def test_older_report_has_no_exception_section(self):
        data = {"generated_at": "today", "totals": dict(update_events=0, updated_repos=0, eol_notifications=0, major_version_notifications=0, warnings=0),
                "update_events": [], "major_version_notifications": [], "eol_notifications": [], "warnings": []}
        self.assertNotIn("Grype Exception Warnings", report.render_markdown(data))
        self.assertEqual(email.event_counts(data, "success", "success")["grype_exceptions"], 0)


if __name__ == "__main__":
    unittest.main()
