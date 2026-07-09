#!/usr/bin/env python3

import argparse
import json
import re
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Any


TABLE_SECTIONS = {
    "Alpine-based images",
    "Images based on official images (or forks)",
    "Descendant images",
    "Version updates from upstream other than the base image",
}

PRODUCT_ALIASES = {
    "_/golang": "go",
    "_/httpd": "apache",
    "_/memcached": "memcached",
    "_/php": "php",
    "_/postgres": "postgresql",
    "apache/solr": "solr",
    "apache/zookeeper": "zookeeper",
    "cachethq/cachet": "cachet",
    "golang": "go",
    "httpd": "apache",
    "matomo-org/matomo": "matomo",
    "node": "nodejs",
    "postgres": "postgresql",
    "prometheus/prometheus": "prometheus",
    "valkey/valkey": "valkey",
    "vinyl-cache/vinyl-cache": "varnish",
    "wordpress": "wordpress",
}

PRODUCT_DISPLAY = {
    "alpine": "Alpine Linux",
    "apache": "Apache HTTP Server",
    "cachet": "Cachet",
    "drupal": "Drupal",
    "go": "Go",
    "mariadb": "MariaDB",
    "matomo": "Matomo",
    "memcached": "Memcached",
    "nginx": "Nginx",
    "nodejs": "Node.js",
    "php": "PHP",
    "postgresql": "PostgreSQL",
    "prometheus": "Prometheus",
    "python": "Python",
    "rabbitmq": "RabbitMQ",
    "redis": "Redis",
    "ruby": "Ruby",
    "solr": "Solr",
    "valkey": "Valkey",
    "varnish": "Varnish",
    "wordpress": "WordPress",
    "zookeeper": "ZooKeeper",
}

LINK_RE = re.compile(r"\[([^\]]+)\]")
CODE_RE = re.compile(r"`([^`]+)`")
HEADING_RE = re.compile(r"^#{3}\s+(.+?)\s*$")
VERSION_RE = re.compile(r"\d+")


@dataclass(frozen=True)
class VersionItem:
    image: str
    product: str
    source: str
    version: str
    section: str


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate a wodby/images update report.")
    parser.add_argument("--readme", default="README.md", help="Path to wodby/images README.md.")
    parser.add_argument("--events-dir", default="", help="Directory containing update event artifacts.")
    parser.add_argument("--output-dir", default="image-update-report", help="Directory for JSON and Markdown report files.")
    parser.add_argument(
        "--eol-warning-days",
        type=int,
        default=90,
        help="Report configured versions that reach EOL within this many days.",
    )
    return parser.parse_args()


def extract_link_label(cell: str) -> str | None:
    match = LINK_RE.search(cell)
    return match.group(1).strip() if match else None


def extract_versions(cell: str) -> list[str]:
    versions: list[str] = []
    for value in CODE_RE.findall(cell):
        for part in re.split(r"[, ]+", value.strip()):
            if part:
                versions.append(part)
    return versions


def product_for_label(label: str) -> str:
    normalized = label.strip()
    lowered = normalized.lower()
    if lowered in PRODUCT_ALIASES:
        return PRODUCT_ALIASES[lowered]

    if lowered.startswith("wodby/"):
        lowered = lowered.split("/", 1)[1]
    elif lowered.startswith("_/"):
        lowered = lowered[2:]
    elif "/" in lowered:
        lowered = lowered.rsplit("/", 1)[1]

    return PRODUCT_ALIASES.get(lowered, lowered)


def split_table_row(line: str) -> list[str]:
    return [cell.strip() for cell in line.strip().strip("|").split("|")]


def parse_readme(path: Path) -> list[VersionItem]:
    items: list[VersionItem] = []
    section = ""

    for line in path.read_text().splitlines():
        heading = HEADING_RE.match(line)
        if heading:
            section = heading.group(1)
            continue

        if section not in TABLE_SECTIONS or not line.startswith("|"):
            continue

        cells = split_table_row(line)
        if not cells or set(cells[0]) <= {"-", " "}:
            continue

        image = extract_link_label(cells[0])
        if not image or not image.startswith("wodby/"):
            continue

        if section == "Alpine-based images":
            if len(cells) < 2:
                continue
            source = "alpine"
            product = "alpine"
            versions = extract_versions(cells[1])
        else:
            if len(cells) < 3:
                continue
            source = extract_link_label(cells[1]) or cells[1]
            product = product_for_label(source)
            versions = extract_versions(cells[2])

        for version in versions:
            items.append(VersionItem(image=image, product=product, source=source, version=version, section=section))

    unique: dict[tuple[str, str, str, str], VersionItem] = {}
    for item in items:
        unique[(item.image, item.product, item.source, item.version)] = item
    return sorted(unique.values(), key=lambda item: (item.product, item.image, version_key(item.version)))


def load_update_events(events_dir: Path | None) -> list[dict[str, Any]]:
    if not events_dir or not events_dir.exists():
        return []

    events: list[dict[str, Any]] = []
    seen: set[tuple[str, str, str, str, str, str, str]] = set()
    for path in sorted(events_dir.rglob("events.jsonl")):
        for raw_line in path.read_text().splitlines():
            line = raw_line.strip()
            if not line:
                continue
            event = json.loads(line)
            key = (
                str(event.get("type") or ""),
                str(event.get("repo") or ""),
                str(event.get("message") or ""),
                str(event.get("version") or ""),
                str(event.get("previous") or ""),
                str(event.get("dir") or ""),
                str(event.get("script") or ""),
            )
            if key in seen:
                continue
            seen.add(key)
            events.append(event)
    return sorted(events, key=lambda event: (str(event.get("repo") or ""), str(event.get("created_at") or "")))


def fetch_json(url: str) -> Any | None:
    request = urllib.request.Request(url, headers={"User-Agent": "wodby-images-update-report/1.0"})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return None
        raise


def version_key(value: Any) -> tuple[int, ...]:
    numbers = VERSION_RE.findall(str(value))
    return tuple(int(number) for number in numbers) if numbers else (0,)


def major_version(value: Any) -> int | None:
    numbers = VERSION_RE.findall(str(value))
    return int(numbers[0]) if numbers else None


def parse_iso_date(value: Any) -> date | None:
    if not isinstance(value, str):
        return None
    try:
        return date.fromisoformat(value)
    except ValueError:
        return None


def product_label(product: str) -> str:
    return PRODUCT_DISPLAY.get(product, product.replace("-", " ").title())


def best_release(product_data: list[dict[str, Any]], version: str) -> dict[str, Any] | None:
    for release in product_data:
        if str(release.get("cycle") or "") == version:
            return release

    candidates = [
        release
        for release in product_data
        if str(release.get("cycle") or "").startswith(f"{version}.")
    ]
    if not candidates:
        return None

    return sorted(candidates, key=lambda release: version_key(release.get("cycle")), reverse=True)[0]


def release_is_active(release: dict[str, Any], today: date) -> bool:
    eol = release.get("eol")
    if eol is False or eol is None:
        return True
    if eol is True:
        return False

    eol_date = parse_iso_date(eol)
    return eol_date is None or eol_date >= today


def latest_active_release(product_data: list[dict[str, Any]], today: date) -> dict[str, Any] | None:
    active = [release for release in product_data if release_is_active(release, today)]
    if not active:
        return None
    return sorted(active, key=lambda release: version_key(release.get("cycle")), reverse=True)[0]


def eol_message(item: VersionItem, release: dict[str, Any], today: date, warning_days: int) -> dict[str, Any] | None:
    eol = release.get("eol")
    display = product_label(item.product)
    cycle = str(release.get("cycle") or item.version)
    version_text = f"`{item.version}`"
    if cycle != item.version:
        version_text = f"`{item.version}` (cycle `{cycle}`)"

    if eol is True:
        return {
            "image": item.image,
            "product": item.product,
            "product_label": display,
            "version": item.version,
            "cycle": cycle,
            "eol": "true",
            "status": "eol",
            "message": f"`{item.image}` uses {display} {version_text}, which is EOL.",
        }

    eol_date = parse_iso_date(eol)
    if eol_date is None:
        return None

    days = (eol_date - today).days
    if days < 0:
        status = "eol"
        text = f"reached EOL on `{eol_date.isoformat()}`"
    elif days <= warning_days:
        status = "upcoming_eol"
        text = f"reaches EOL on `{eol_date.isoformat()}` in {days} days"
    else:
        return None

    return {
        "image": item.image,
        "product": item.product,
        "product_label": display,
        "version": item.version,
        "cycle": cycle,
        "eol": eol_date.isoformat(),
        "days_until_eol": days,
        "status": status,
        "message": f"`{item.image}` uses {display} {version_text}, which {text}.",
    }


def analyze_versions(items: list[VersionItem], warning_days: int) -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[str]]:
    today = date.today()
    product_cache: dict[str, list[dict[str, Any]] | None] = {}
    warnings: list[str] = []
    eol_notifications: list[dict[str, Any]] = []
    major_notifications: list[dict[str, Any]] = []

    def product_data(product: str) -> list[dict[str, Any]] | None:
        if product in product_cache:
            return product_cache[product]
        try:
            payload = fetch_json(f"https://endoflife.date/api/{product}.json")
        except Exception as exc:  # noqa: BLE001
            warnings.append(f"Failed to fetch EOL data for `{product}`: {exc}")
            product_cache[product] = None
            return None
        if not isinstance(payload, list):
            product_cache[product] = None
            return None
        product_cache[product] = payload
        return payload

    for item in items:
        data = product_data(item.product)
        if data is None:
            continue
        release = best_release(data, item.version)
        if release is None:
            continue
        notification = eol_message(item, release, today, warning_days)
        if notification is not None:
            eol_notifications.append(notification)

    by_product: dict[str, list[VersionItem]] = {}
    for item in items:
        by_product.setdefault(item.product, []).append(item)

    for product, product_items in sorted(by_product.items()):
        data = product_data(product)
        if data is None:
            continue
        configured_majors = [major_version(item.version) for item in product_items]
        configured_majors = [value for value in configured_majors if value is not None]
        if not configured_majors:
            continue
        latest = latest_active_release(data, today)
        if latest is None:
            continue
        latest_cycle = str(latest.get("cycle") or "")
        latest_major = major_version(latest_cycle)
        highest_configured_major = max(configured_majors)
        if latest_major is None or latest_major <= highest_configured_major:
            continue
        images = sorted({item.image for item in product_items})
        display = product_label(product)
        major_notifications.append(
            {
                "product": product,
                "product_label": display,
                "latest": latest_cycle,
                "highest_configured_major": highest_configured_major,
                "images": images,
                "message": (
                    f"New {display} major version `{latest_cycle}` is available "
                    f"(highest configured major: `{highest_configured_major}`; images: "
                    f"{', '.join(f'`{image}`' for image in images)})."
                ),
            }
        )

    eol_notifications = sorted(
        eol_notifications,
        key=lambda item: (
            item.get("days_until_eol", -99999),
            item.get("product_label", ""),
            item.get("image", ""),
            item.get("version", ""),
        ),
    )
    return eol_notifications, major_notifications, warnings


def render_markdown(report: dict[str, Any]) -> str:
    lines: list[str] = []
    totals = report["totals"]
    lines.append("# Wodby Images Update Report")
    lines.append("")
    lines.append(f"Report date: {report['generated_at']}")
    lines.append("")
    lines.append("## Summary")
    lines.append("")
    lines.append(f"- Update events: {totals['update_events']}")
    lines.append(f"- Updated repos: {totals['updated_repos']}")
    lines.append(f"- EOL notifications: {totals['eol_notifications']}")
    lines.append(f"- New major version notifications: {totals['major_version_notifications']}")
    lines.append(f"- Warnings: {totals['warnings']}")
    lines.append("")

    if report["update_events"]:
        lines.append("## Updates")
        lines.append("")
        for event in report["update_events"]:
            event_type = str(event.get("type") or "event").replace("_", " ")
            repo = event.get("repo") or "unknown"
            message = event.get("message") or ""
            version = event.get("version") or ""
            suffix = f" (`{version}`)" if version else ""
            lines.append(f"- `{repo}`: {event_type}: {message}{suffix}")
        lines.append("")

    if report["major_version_notifications"]:
        lines.append("## New Major Versions")
        lines.append("")
        for item in report["major_version_notifications"]:
            lines.append(f"- {item['message']}")
        lines.append("")

    if report["eol_notifications"]:
        lines.append("## EOL Notifications")
        lines.append("")
        for item in report["eol_notifications"]:
            lines.append(f"- {item['message']}")
        lines.append("")

    if report["warnings"]:
        lines.append("## Warnings")
        lines.append("")
        for warning in report["warnings"]:
            lines.append(f"- {warning}")
        lines.append("")

    if not (report["update_events"] or report["major_version_notifications"] or report["eol_notifications"] or report["warnings"]):
        lines.append("No reportable image update events were found.")
        lines.append("")

    return "\n".join(lines).rstrip() + "\n"


def generate_report(args: argparse.Namespace) -> dict[str, Any]:
    readme = Path(args.readme)
    events_dir = Path(args.events_dir) if args.events_dir else None
    items = parse_readme(readme)
    update_events = load_update_events(events_dir)
    eol_notifications, major_notifications, warnings = analyze_versions(items, args.eol_warning_days)
    updated_repos = sorted({event.get("repo") for event in update_events if event.get("repo")})

    return {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "readme": str(readme),
        "eol_warning_days": args.eol_warning_days,
        "totals": {
            "readme_version_items": len(items),
            "update_events": len(update_events),
            "updated_repos": len(updated_repos),
            "eol_notifications": len(eol_notifications),
            "major_version_notifications": len(major_notifications),
            "warnings": len(warnings),
        },
        "updated_repos": updated_repos,
        "update_events": update_events,
        "eol_notifications": eol_notifications,
        "major_version_notifications": major_notifications,
        "warnings": warnings,
    }


def main() -> int:
    args = parse_args()
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    report = generate_report(args)
    (output_dir / "image-update-report.json").write_text(json.dumps(report, indent=2))
    (output_dir / "image-update-report.md").write_text(render_markdown(report))
    print(render_markdown(report))
    return 0


if __name__ == "__main__":
    sys.exit(main())
