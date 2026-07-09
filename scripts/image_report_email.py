#!/usr/bin/env python3

import argparse
import html
import json
import os
import smtplib
import ssl
from email.message import EmailMessage
from pathlib import Path
from typing import Any


SUCCESSFUL_WORKFLOW_RESULTS = {"success", "skipped"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Send a consolidated wodby/images update report email.")
    parser.add_argument("report_dir", help="Directory containing image-update-report.json.")
    parser.add_argument("--run-url", default="", help="GitHub Actions run URL.")
    parser.add_argument("--event", default="", help="GitHub Actions event name.")
    parser.add_argument("--sha", default="", help="Git commit SHA.")
    parser.add_argument("--workflow-result", default="", help="Aggregated update job result.")
    parser.add_argument("--artifact-result", default="", help="Report artifact download step result.")
    return parser.parse_args()


def load_report(report_dir: Path) -> dict[str, Any]:
    return json.loads((report_dir / "image-update-report.json").read_text())


def workflow_result_failed(workflow_result: str) -> bool:
    text = workflow_result.strip()
    if not text:
        return False
    parts = [part.strip() for part in text.split(",") if part.strip()]
    for part in parts:
        result = part.rsplit("=", 1)[-1].strip().lower()
        if result not in SUCCESSFUL_WORKFLOW_RESULTS:
            return True
    return False


def artifact_result_failed(artifact_result: str) -> bool:
    text = artifact_result.strip().lower()
    return bool(text and text not in SUCCESSFUL_WORKFLOW_RESULTS)


def event_counts(report: dict[str, Any], workflow_result: str, artifact_result: str) -> dict[str, int]:
    totals = report.get("totals") or {}
    return {
        "workflow_failures": 1 if workflow_result_failed(workflow_result) else 0,
        "artifact_failures": 1 if artifact_result_failed(artifact_result) else 0,
        "updated_repos": int(totals.get("updated_repos") or 0),
        "update_events": int(totals.get("update_events") or 0),
        "eol_notifications": int(totals.get("eol_notifications") or 0),
        "major_version_notifications": int(totals.get("major_version_notifications") or 0),
        "warnings": int(totals.get("warnings") or 0),
    }


def has_email_worthy_events(counts: dict[str, int]) -> bool:
    return (
        counts["workflow_failures"] > 0
        or counts["artifact_failures"] > 0
        or counts["update_events"] > 0
    )


def append_messages(lines: list[str], title: str, items: list[dict[str, Any]]) -> None:
    if not items:
        return
    lines.append(title)
    lines.append("")
    for item in items:
        lines.append(f"- {item.get('message', '')}")
    lines.append("")


def append_update_events(lines: list[str], events: list[dict[str, Any]]) -> None:
    if not events:
        return
    lines.append("Updates")
    lines.append("")
    for event in events:
        event_type = str(event.get("type") or "event").replace("_", " ")
        repo = event.get("repo") or "unknown"
        message = event.get("message") or ""
        version = event.get("version") or ""
        suffix = f" ({version})" if version else ""
        lines.append(f"- {repo}: {event_type}: {message}{suffix}")
    lines.append("")


def build_body(
    report: dict[str, Any],
    counts: dict[str, int],
    *,
    run_url: str,
    event: str,
    sha: str,
    workflow_result: str,
    artifact_result: str,
) -> str:
    lines: list[str] = []
    lines.append("Wodby images update report events were detected.")
    lines.append("")
    lines.append(f"Run: {run_url or 'unknown'}")
    lines.append(f"Event: {event or 'unknown'}")
    lines.append(f"Commit: {sha or 'unknown'}")
    lines.append(f"Update job result: {workflow_result or 'unknown'}")
    lines.append(f"Artifact download result: {artifact_result or 'unknown'}")
    lines.append(f"Report date: {report.get('generated_at') or 'unknown'}")
    lines.append("")
    lines.append("Summary:")
    for key, value in counts.items():
        lines.append(f"- {key.replace('_', ' ')}: {value}")
    lines.append("")

    if counts["workflow_failures"]:
        lines.append("Workflow Failure")
        lines.append("")
        lines.append("One or more update jobs did not complete successfully. Check the run URL above.")
        lines.append("")

    if counts["artifact_failures"]:
        lines.append("Report Artifact Failure")
        lines.append("")
        lines.append("Report artifacts could not be downloaded. Check the workflow run logs for collection errors.")
        lines.append("")

    append_update_events(lines, report.get("update_events") or [])
    append_messages(lines, "New Major Versions", report.get("major_version_notifications") or [])
    append_messages(lines, "EOL Notifications", report.get("eol_notifications") or [])

    warnings = [{"message": warning} for warning in report.get("warnings") or []]
    append_messages(lines, "Warnings", warnings)
    return "\n".join(lines).rstrip() + "\n"


def html_inline_markdown(text: Any) -> str:
    parts = str(text).split("`")
    rendered = []
    for index, part in enumerate(parts):
        escaped = html.escape(part)
        if index % 2:
            rendered.append(
                "<code style=\"background:#f3f4f6;border-radius:3px;padding:1px 4px;"
                "font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;\">"
                f"{escaped}</code>"
            )
        else:
            rendered.append(escaped)
    return "".join(rendered)


def html_message_list(items: list[dict[str, Any]]) -> str:
    if not items:
        return ""
    rows = "".join(f"<li>{html_inline_markdown(item.get('message', ''))}</li>" for item in items)
    return f"<ul style=\"margin:8px 0 0 20px;padding:0;\">{rows}</ul>"


def html_section(title: str, items: list[dict[str, Any]]) -> str:
    if not items:
        return ""
    return (
        f"<h2 style=\"margin:24px 0 10px 0;font-size:18px;color:#111827;\">{html.escape(title)}</h2>"
        f"{html_message_list(items)}"
    )


def html_update_events(events: list[dict[str, Any]]) -> str:
    if not events:
        return ""
    items = []
    for event in events:
        event_type = str(event.get("type") or "event").replace("_", " ")
        repo = event.get("repo") or "unknown"
        message = event.get("message") or ""
        version = event.get("version") or ""
        suffix = f" (`{version}`)" if version else ""
        items.append({"message": f"`{repo}`: {event_type}: {message}{suffix}"})
    return html_section("Updates", items)


def build_html_body(
    report: dict[str, Any],
    counts: dict[str, int],
    *,
    run_url: str,
    event: str,
    sha: str,
    workflow_result: str,
    artifact_result: str,
) -> str:
    status_color = "#991b1b" if counts["workflow_failures"] or counts["artifact_failures"] else "#166534"
    summary_rows = "".join(
        "<tr>"
        f"<td style=\"padding:6px 12px;border-bottom:1px solid #e5e7eb;color:#374151;\">{html.escape(key.replace('_', ' '))}</td>"
        f"<td style=\"padding:6px 12px;border-bottom:1px solid #e5e7eb;color:#111827;text-align:right;\"><strong>{value}</strong></td>"
        "</tr>"
        for key, value in counts.items()
    )
    run_value = (
        f"<a href=\"{html.escape(run_url)}\" style=\"color:#2563eb;\">{html.escape(run_url)}</a>"
        if run_url
        else "unknown"
    )
    body = [
        "<!doctype html><html><body style=\"margin:0;padding:0;background:#ffffff;color:#111827;"
        "font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;font-size:14px;line-height:1.5;\">",
        "<div style=\"max-width:920px;margin:0 auto;padding:24px;\">",
        "<h1 style=\"margin:0 0 8px 0;font-size:24px;color:#111827;\">Wodby Images Update Report</h1>",
        "<p style=\"margin:0 0 18px 0;color:#4b5563;\">Image update report events were detected.</p>",
        "<table role=\"presentation\" cellspacing=\"0\" cellpadding=\"0\" style=\"border-collapse:collapse;margin:0 0 18px 0;\">",
        f"<tr><td style=\"padding:2px 14px 2px 0;color:#6b7280;\">Run</td><td style=\"padding:2px 0;\">{run_value}</td></tr>",
        f"<tr><td style=\"padding:2px 14px 2px 0;color:#6b7280;\">Event</td><td style=\"padding:2px 0;\">{html.escape(event or 'unknown')}</td></tr>",
        f"<tr><td style=\"padding:2px 14px 2px 0;color:#6b7280;\">Commit</td><td style=\"padding:2px 0;\">{html.escape(sha or 'unknown')}</td></tr>",
        f"<tr><td style=\"padding:2px 14px 2px 0;color:#6b7280;\">Update job result</td><td style=\"padding:2px 0;color:{status_color};\"><strong>{html.escape(workflow_result or 'unknown')}</strong></td></tr>",
        f"<tr><td style=\"padding:2px 14px 2px 0;color:#6b7280;\">Artifact download result</td><td style=\"padding:2px 0;color:{status_color};\"><strong>{html.escape(artifact_result or 'unknown')}</strong></td></tr>",
        f"<tr><td style=\"padding:2px 14px 2px 0;color:#6b7280;\">Report date</td><td style=\"padding:2px 0;\">{html.escape(str(report.get('generated_at') or 'unknown'))}</td></tr>",
        "</table>",
        "<h2 style=\"margin:24px 0 10px 0;font-size:18px;color:#111827;\">Summary</h2>",
        "<table role=\"presentation\" cellspacing=\"0\" cellpadding=\"0\" style=\"border-collapse:collapse;min-width:360px;border:1px solid #e5e7eb;border-radius:6px;\">",
        summary_rows,
        "</table>",
    ]
    if counts["workflow_failures"]:
        body.append(
            "<div style=\"margin:20px 0;padding:12px;border:1px solid #fecaca;border-radius:6px;background:#fef2f2;color:#991b1b;\">"
            "<strong>Workflow Failure</strong><br>One or more update jobs did not complete successfully. Check the run URL above."
            "</div>"
        )
    if counts["artifact_failures"]:
        body.append(
            "<div style=\"margin:20px 0;padding:12px;border:1px solid #fecaca;border-radius:6px;background:#fef2f2;color:#991b1b;\">"
            "<strong>Report Artifact Failure</strong><br>Report artifacts could not be downloaded. Check the workflow run logs for collection errors."
            "</div>"
        )
    body.append(html_update_events(report.get("update_events") or []))
    body.append(html_section("New Major Versions", report.get("major_version_notifications") or []))
    body.append(html_section("EOL Notifications", report.get("eol_notifications") or []))
    warnings = [{"message": warning} for warning in report.get("warnings") or []]
    body.append(html_section("Warnings", warnings))
    body.append("</div></body></html>")
    return "".join(body)


def build_subject(counts: dict[str, int], sha: str) -> str:
    status = "failed" if counts["workflow_failures"] or counts["artifact_failures"] else "events"
    short_sha = sha[:7] if sha else "unknown"
    return (
        f"[images] report {status}: "
        f"{counts['updated_repos']} updated repos, "
        f"{counts['eol_notifications']} EOL notices, "
        f"{counts['major_version_notifications']} new-major notices ({short_sha})"
    )


def split_recipients(value: str) -> list[str]:
    return [item.strip() for item in value.replace(";", ",").split(",") if item.strip()]


def send_email(subject: str, body: str, html_body: str) -> bool:
    smtp_host = os.environ.get("SMTP_HOST", "").strip()
    smtp_port = int(os.environ.get("SMTP_PORT") or "587")
    smtp_user = os.environ.get("SMTP_USERNAME", "").strip()
    smtp_password = os.environ.get("SMTP_PASSWORD", "")
    mail_from = os.environ.get("REPORT_EMAIL_FROM", "").strip() or smtp_user
    recipients = split_recipients(os.environ.get("REPORT_EMAIL_TO", ""))
    use_ssl = os.environ.get("SMTP_SSL", "").lower() in ("1", "true", "yes")
    use_starttls = os.environ.get("SMTP_STARTTLS", "true").lower() not in ("0", "false", "no")

    missing = []
    if not smtp_host:
        missing.append("SMTP_HOST")
    if not mail_from:
        missing.append("REPORT_EMAIL_FROM")
    if not recipients:
        missing.append("REPORT_EMAIL_TO")
    if missing:
        print(f"Email not sent because required configuration is missing: {', '.join(missing)}")
        return False

    message = EmailMessage()
    message["Subject"] = subject
    message["From"] = mail_from
    message["To"] = ", ".join(recipients)
    message.set_content(body)
    message.add_alternative(html_body, subtype="html")

    context = ssl.create_default_context()
    if use_ssl:
        with smtplib.SMTP_SSL(smtp_host, smtp_port, context=context, timeout=60) as smtp:
            if smtp_user or smtp_password:
                smtp.login(smtp_user, smtp_password)
            smtp.send_message(message)
    else:
        with smtplib.SMTP(smtp_host, smtp_port, timeout=60) as smtp:
            smtp.ehlo()
            if use_starttls:
                smtp.starttls(context=context)
                smtp.ehlo()
            if smtp_user or smtp_password:
                smtp.login(smtp_user, smtp_password)
            smtp.send_message(message)
    return True


def main() -> int:
    args = parse_args()
    report = load_report(Path(args.report_dir))
    counts = event_counts(report, args.workflow_result, args.artifact_result)

    if not has_email_worthy_events(counts):
        print("No image update events or workflow failures were found.")
        return 0

    subject = build_subject(counts, args.sha)
    body = build_body(
        report,
        counts,
        run_url=args.run_url,
        event=args.event,
        sha=args.sha,
        workflow_result=args.workflow_result,
        artifact_result=args.artifact_result,
    )
    html_body = build_html_body(
        report,
        counts,
        run_url=args.run_url,
        event=args.event,
        sha=args.sha,
        workflow_result=args.workflow_result,
        artifact_result=args.artifact_result,
    )
    print(subject)
    print("")
    print(body)
    if send_email(subject, body, html_body):
        print("Email sent.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
