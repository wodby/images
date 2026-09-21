# Docker images auto updater

[![Build Status](https://github.com/wodby/images/workflows/Update/badge.svg)](https://github.com/wodby/images/actions)

## Image revisions

For images that package upstream software, tags separate the upstream software
version from the Wodby image revision. Wodby software such as Edge Alpine and
Backup uses its own semantic product versions for both Git and Docker tags.
Edge 3.x and 2.x identify different runtime compatibility contracts. These
repositories do not use the image revision sequence.

For packaged upstream software, choose a major/minor release line or an exact
upstream version. The first release uses `r0` everywhere: Git tag `r0` and, for example, Docker tags `11-r0`,
`11.4-r0`, and `11.4.2-r0`. Subsequent releases follow the counters below:

| Example Docker tag | Revision counter | Matching Git tag |
|--------------------|------------------|------------------|
| `wodby/mariadb:11-r102` | Repository release 102 | `11-r102` |
| `wodby/mariadb:11.4-r102` | Repository release 102 | `11.4-r102` |
| `wodby/mariadb:11.4.2-r0` | First revision of exactly 11.4.2 | `11.4.2-r0` |

These illustrative aliases all point to the primary Git release tag `r102`'s
commit. A major alias selects the supported minor line designated for that major.
Development variants retain their qualifier, such as `wodby/php:8.5-dev-r102`
and `wodby/php:8.5.10-dev-r0`. Images without an upstream-version prefix use the
repository release directly, such as `wodby/sshd:r102`.

- Git release tags are `r0`, `r1`, `r2`, and so on. The counter increases per repository
  and is shared by its runtime versions, variants, and architectures.
  Major/minor Docker tags use this counter. It never resets when an upstream
  version changes. Numbers can have gaps.
- Full-version tags start at `r0` for each exact upstream version. The next
  repository release containing that same version uses `r1`, and so on. A new
  upstream version starts at `r0` again. Variants and architectures share the
  counter. Failed release attempts can leave gaps; retries reuse their number.
- Alias tag descriptions use the primary release notes to explain what changed.
- After the images and any versioned aliases publish successfully, CI creates one
  GitHub Release named after the primary tag, such as `r2`, with its annotated tag
  notes. Versioned aliases do not get separate GitHub Releases. Retrying a workflow
  preserves an existing published release; a manually prepared draft needs review.
- Every published versioned revision tag gets a matching annotated Git alias
  pointing to the primary release commit. Only primary Git tags trigger builds.
  Dropping a major or minor line stops new releases for it; existing Docker and
  Git revision tags remain available.
- Each new image release gets a new revision, including releases that adopt
  dependency or security fixes without changing the upstream software version.
  CI retries do not allocate another revision.
- Revisions identify releases; they do not indicate compatibility. Review the
  release notes before upgrading. Breaking configuration, permission, storage,
  or startup changes require explicit migration instructions.
- Published revision tags must not be reassigned to different image contents.
  Pin an image digest when the exact artifact must be enforced independently
  of registry tag settings. Floating tags such as `11.4` and `latest` remain mutable.
- Previously published image tags remain available. Parent-image and Docker4X updates
  accept both formats, prefer published revisions for the selected runtime and
  variant, and never automatically move from a revision back to a legacy tag.

Upstream version formats differ. PostgreSQL `17.11` and Squid `7.6` are complete
versions, so `17.11-r0` and `7.6-r0` use the full-version counter; `17-r102` and
`7-r102` use the repository counter. Supabase PostgreSQL uses its complete bundle
version, such as `17.6.1.136-r0`. WordPress initial releases named `7.2` use
`7.2.0-r0` for the exact version, keeping `7.2-r102` for the minor line.

## Update reports

Email digests and consolidated reports include a **Grype Exception Warnings** section
when catalog image repositories contain configured `ignore` rules. Each warning shows
the repository, branch, complete rule scope, and configuration URL so exceptions can
be reviewed and removed after a fix is adopted. The report checks the default branch,
using the first conventional `.grype.yaml`, `.grype.yml`, `.grype/config.yaml`, or `.grype/config.yml` file. Custom config paths,
environment-only rules, and VEX files are not inspected. These are configured rules,
not confirmed matches from a vulnerability scan. Lookup and parsing errors appear in
the general warnings section.

Exceptions alone do not trigger an email; digests retain the existing update-event
and workflow/artifact-failure triggers. To generate a report locally, first install
its dependencies with `python -m pip install -r scripts/requirements.txt`.

## Auto-updated images

### Alpine-based images

| Image             | Alpine version |
|-------------------|----------------|
| [wodby/mariadb]   | `3.22`         |
| [wodby/nginx]     | `3.23`         |
| [wodby/opensmtpd] | `3.23`         |
| [wodby/vinyl]     | `3.22`, `3.23` |
| [wodby/squid]     | `3.24`         |

### Images based on official images (or forks)

- Minor/patch version update
- Rebuild against updated base image
- Rebuild `wodby/alpine` against complete new gotpl releases
- New image revision released on version update
- New image revision released on Alpine Linux update
- New `wodby/alpine` revision when tested package upgrades fix known CVEs. All
  supported variants and architectures are compared with the last revision using
  one vulnerability database snapshot. Digest-only changes do not trigger releases.
  Release notes list package versions and CVEs; release builds verify those fixes.

| Image             | Upstream (base image) | Versions                               |
|-------------------|-----------------------|----------------------------------------|
| [wodby/alpine]    | [alpine]              | `3.24`, `3.23`, `3.22`, `3.21` |
| [wodby/apache]    | [_/httpd]             | `2.4`                                  |
| [wodby/memcached] | [_/memcached]         | `1`                                    |
| [wodby/mysql]     | [_/mysql]             | `8.0`                                  |
| [wodby/node]      | [node]                | `26`, `24`, `22`                       |
| [wodby/php]       | [_/php]               | `8.5`, `8.4`, `8.3`, `8.2`             |
| [wodby/postgres]  | [_/postgres]          | `18`, `17`, `16`, `15`, `14`           |
| [wodby/supabase-postgres] | [supabase/postgres] | `17` |
| [wodby/python]    | [python]              | `3.14`, `3.13`, `3.12`, `3.11`, `3.10` |
| [wodby/go]        | [_/golang]            | `1.27`, `1.26`                         |
| [wodby/valkey]    | [valkey/valkey]       | `9.0`, `8.1`, `8.0`, `7.2`             |
| [wodby/redis]     | [redis]               | `8.6`, `8.4`, `8.2`, `7.4`             |
| [wodby/ruby]      | [ruby]                | `4.0`, `3.4`, `3.3`                    |
| [wodby/rabbitmq]  | [rabbitmq]            | `4.3`, `4.2`                           |

Supabase PostgreSQL is monitored for newer bundles within its pinned major version and for changes to the pinned tag digest. Updates produce manual-review report events; they do not automatically change the image or create releases because initialization SQL and backup compatibility must be validated together.

### Descendant images

`wodby/backup` checks the digest of its `wodby/alpine:latest` base on each updater
run. A changed digest produces a new semantic patch release, such as `2.3.3`.
The updater publishes the pin commit and annotated release tag together. Backup's
release workflow tests the image, publishes the matching Docker tag, and then
creates a GitHub Release with that same version. An unchanged digest creates no
release. A failed image build can be retried with the existing tag.

- Rebuild against updated base image
- Update the base image revision
- New release using the image revision or product version format

| Image                 | Upstream (base image) | Versions                   |
|-----------------------|-----------------------|----------------------------|
| [wodby/edge-alpine]   | [wodby/nginx]         | `1.31`                     |
| [wodby/drupal-php]    | [wodby/php]           | `8.5`, `8.4`, `8.3`, `8.2` |
| [wodby/drupal]        | [wodby/drupal-php]    | `8.5`, `8.4`, `8.3`, `8.2` |
| [wodby/drupal-cms]    | [wodby/drupal-php]    | `8.4`                      |
| [wodby/matomo]        | [wodby/php]           | `8.2`                      |
| [wodby/webgrind]      | [wodby/php]           | `8.2`                      |
| [wodby/wordpress-php] | [wodby/php]           | `8.5`, `8.4`, `8.3`, `8.2` |
| [wodby/wordpress]     | [wodby/wordpress-php] | `8.5`, `8.4`, `8.3`, `8.2` |
| [wodby/xhprof]        | [wodby/php]           | `8.2`                      |
| [wodby/laravel-php]   | [wodby/php]           | `8.5`, `8.4`, `8.3`, `8.2` |

### Version updates from upstream other than the base image

- Minor/patch version updates
- New release using the image revision or product version format

| Image                 | Upstream                | Versions                                 |
|-----------------------|-------------------------|------------------------------------------|
| [wodby/adminer]       | [vrana/adminer]         | `6`                                      |
| [wodby/cachet]        | [CachetHQ/Cachet]       | `2`                                      |
| [wodby/drupal]        | [drupal]                | `11`, `10`                               |
| [wodby/drupal-cms]    | [drupal-cms]            | `2`                                      |
| [wodby/mariadb]       | [mariadb]               | `11.8`, `11.4`, `11.2`, `10.11`,  `10.6` |
| [wodby/matomo]        | [matomo-org/matomo]     | `5`                                      |
| [wodby/nginx]         | [nginx]                 | `1.31`, `1.30`                           |
| [wodby/prometheus]    | [prometheus/prometheus] | `3.13`                                   |
| [wodby/vinyl]         | [vinyl-cache/vinyl-cache] | `8.0`, `6.0`                             |
| [wodby/webgrind]      | [jokkedk/webgrind]      | `1`                                      |
| [wodby/wordpress]     | [wordpress]             | `7`                                      |
| [wodby/xhprof]        | [longxinH/xhprof]       | `2`                                      |
| [wodby/solr]          | [apache/solr]           | `10`, `9`                                |
| [wodby/zookeeper]     | [apache/zookeeper]      | `3.9`                                    |
| [wodby/openclaw]      | [openclaw/openclaw]     | `2026`                                   |

### Docker4X projects

Update image revision tags

| Project                  |
|--------------------------|
| [wodby/docker4drupal]    |
| [wodby/docker4php]       |
| [wodby/docker4python]    |
| [wodby/docker4ruby]      |
| [wodby/docker4wordpress] |
| [wodby/docker4laravel]   |

### Tooling projects

Update runtime versions within the configured compatibility line.

| Project       | Runtime | Policy |
|---------------|---------|--------|
| [wodby/gotpl] | Go      | Patch updates only; EOL lines are reported for manual migration |

### Edge runtime dependencies

[wodby/edge-alpine] automatically updates NGINX 1.31, lego 4.x, s6-overlay 3.x, gotpl 0.6.x, and etcd-client 3.6 patches. Confd advances only to stable releases descended from its current source pin; older releases are skipped and divergent histories are reported. Go build images remain on their configured compatibility line.

Runtime component updates appear in release notes; compiler versions and digests remain in logs and source diffs. Every release waits for the Edge build, runtime tests, and vulnerability scan. Major-line migrations and conflicts with custom source patches require review. The explicit Go library overrides remain manual.

Not automated:

- Adding new minor/major version
- Moving gotpl to a new Go minor line
- Rebase to a new major Alpine version
- Switching the latest version
- [wodby/opensmtpd] (installed from Alpine repository package)
- [wodby/adminer] not auto-updates for the base image (php:8.4-apache)

[adoptium/containers]: https://github.com/adoptium/containers

[alpine]: https://github.com/gliderlabs/docker-alpine

[CachetHQ/Cachet]: https://github.com/CachetHQ/Cachet

[drupal]: https://github.com/drupal/drupal

[drupal-cms]: https://git.drupalcode.org/project/cms

[_/httpd]: https://hub.docker.com/_/httpd

[jokkedk/webgrind]: https://github.com/jokkedk/webgrind

[mariadb]: https://github.com/MariaDB/server

[openclaw/openclaw]: https://github.com/openclaw/openclaw

[prometheus/prometheus]: https://github.com/prometheus/prometheus

[matomo-org/matomo]: https://github.com/matomo-org/matomo

[memcached]: https://github.com/docker-library/memcached

[nginx]: https://github.com/docker-library/nginx

[node]: https://github.com/docker-library/node

[php]: https://github.com/docker-library/php

[postgres]: https://github.com/docker-library/postgres

[python]: https://github.com/docker-library/python

[valkey]: https://github.com/valkey-io/valkey-container

[redis]: https://github.com/docker-library/redis

[ruby]: https://github.com/docker-library/ruby

[rabbitmq]: https://github.com/docker-library/rabbitmq

[vrana/adminer]: https://github.com/vrana/adminer

[longxinH/xhprof]: https://github.com/longxinH/xhprof

[apache/solr]: https://github.com/apache/solr

[apache/zookeeper]: https://github.com/apache/zookeeper

[wodby/solr]: https://github.com/wodby/solr

[wodby/zookeeper]: https://github.com/wodby/zookeeper

[wodby/adminer]: https://github.com/wodby/adminer

[wodby/alpine]: https://github.com/wodby/alpine

[wodby/apache]: https://github.com/wodby/apache

[_/memcached]: https://hub.docker.com/_/memcached

[_/mysql]: https://hub.docker.com/_/mysql

[_/postgres]: https://hub.docker.com/_/postgres

[_/php]: https://hub.docker.com/_/php

[_/golang]: https://hub.docker.com/_/golang

[valkey/valkey]: https://hub.docker.com/r/valkey/valkey

[vinyl-cache/vinyl-cache]: https://code.vinyl-cache.org/vinyl-cache/vinyl-cache

[wodby/cachet]: https://github.com/wodby/cachet

[wodby/docker4drupal]: https://github.com/wodby/docker4drupal

[wodby/docker4php]: https://github.com/wodby/docker4php

[wodby/docker4python]: https://github.com/wodby/docker4python

[wodby/docker4ruby]: https://github.com/wodby/docker4ruby

[wodby/docker4wordpress]: https://github.com/wodby/docker4wordpress

[wodby/docker4laravel]: https://github.com/wodby/docker4laravel

[wodby/gotpl]: https://github.com/wodby/gotpl

[wodby/drupal-php]: https://github.com/wodby/drupal-php

[wodby/edge-alpine]: https://github.com/wodby/edge-alpine

[wodby/laravel-php]: https://github.com/wodby/laravel-php

[wodby/drupal]: https://github.com/wodby/drupal

[wodby/drupal-cms]: https://github.com/wodby/drupal-cms

[wodby/mariadb]: https://github.com/wodby/mariadb

[wodby/matomo]: https://github.com/wodby/matomo

[wodby/memcached]: https://github.com/wodby/memcached

[wodby/mysql]: https://github.com/wodby/mysql

[wodby/nginx]: https://github.com/wodby/nginx

[wodby/node]: https://github.com/wodby/node

[wodby/openjdk]: https://github.com/wodby/openjdk

[wodby/opensmtpd]: https://github.com/wodby/opensmtpd

[wodby/openclaw]: https://github.com/wodby/openclaw

[wodby/php]: https://github.com/wodby/php

[wodby/postgres]: https://github.com/wodby/postgres

[wodby/prometheus]: https://github.com/wodby/prometheus

[wodby/python]: https://github.com/wodby/python

[wodby/go]: https://github.com/wodby/go

[wodby/valkey]: https://github.com/wodby/valkey

[wodby/redis]: https://github.com/wodby/redis

[wodby/ruby]: https://github.com/wodby/ruby

[wodby/rabbitmq]: https://github.com/wodby/rabbitmq

[wodby/vinyl]: https://github.com/wodby/vinyl

[wodby/webgrind]: https://github.com/wodby/webgrind

[wodby/wordpress-php]: https://github.com/wodby/wordpress-php

[wodby/wordpress]: https://github.com/wodby/wordpress

[wodby/xhprof]: https://github.com/wodby/xhprof

[wodby/squid]: https://github.com/wodby/squid

[wordpress]: https://github.com/WordPress/WordPress

[wodby/supabase-postgres]: https://github.com/wodby/supabase-postgres

[supabase/postgres]: https://github.com/supabase/postgres

## Base image updates

Image Makefiles consume `base-images.mk` to pass an exact `repository:tag@digest`
reference to Docker. The updater compares these digests instead of Docker Hub
timestamps. It resolves the actual build tag, including variants such as
`fpm-alpine`, `dev`, and `dev-macos`. Pins use the multi-platform image index.

Version and image-revision updates resolve all affected references before changing
the pins. A missing tag, invalid response, or failed lookup leaves the pin file
unchanged. Digest-only changes trigger rebuilds. Backup also creates a semantic
patch release for each changed base digest; other images retain their version
and Alpine release rules. A committed pin is a build input, not proof of a successful build; failed image builds can be
retried using the same commit and digest.

Images that only track application releases keep their existing update flow.
