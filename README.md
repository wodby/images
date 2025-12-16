# Docker images auto updater

[![Build Status](https://github.com/wodby/images/workflows/Update/badge.svg)](https://github.com/wodby/images/actions)

## Auto-updated images

### Alpine-based images

| Image             | Alpine version |
|-------------------|----------------|
| [wodby/mariadb]   | `3.22`         |
| [wodby/nginx]     | `3.22`         |
| [wodby/opensmtpd] | `3.21`         |
| [wodby/varnish]   | `3.22`         |
| [wodby/squid]     | `3.17`         |

### Images based on official images (or forks)

- Minor/patch version update
- Rebuild against updated base image
- New stability tag released on version update
- New stability tag released on Alpine Linux update

| Image             | Upstream (base image) | Versions                               |
|-------------------|-----------------------|----------------------------------------|
| [wodby/alpine]    | [alpine]              | `3.23`, `3.22`, `3.21`, `3.20`         |
| [wodby/apache]    | [_/httpd]             | `2.4`                                  |
| [wodby/memcached] | [_/memcached]         | `1`                                    |
| [wodby/node]      | [node]                | `24`, `22`, `20`                       |
| [wodby/php]       | [_/php]               | `8.5`, `8.4`, `8.3`, `8.2`, `8.1`      |
| [wodby/postgres]  | [_/postgres]          | `18`, `17`, `16`, `15`, `14`           |
| [wodby/python]    | [python]              | `3.14`, `3.13`, `3.12`, `3.11`, `3.10` |
| [wodby/valkey]    | [valkey/valkey]       | `9.0`, `8.1`, `8.0`, `7.2`             |
| [wodby/redis]     | [redis]               | `8.2`, `8.0`, `7.4`                    |
| [wodby/ruby]      | [ruby]                | `3.4`, `3.3`, `3.2`                    |

### Descendant images

- Rebuild against updated base image
- Rebase to the new stability tag
- New stability tag release

| Image                 | Upstream (base image) | Versions                          | Stability branch |
|-----------------------|-----------------------|-----------------------------------|------------------|
| [wodby/drupal-php]    | [wodby/php]           | `8.5`, `8.4`, `8.3`, `8.2`, `8.1` | `4.x`            |
| [wodby/drupal]        | [wodby/drupal-php]    | `8.4`, `8.3`, `8.2`, `8.1`        | `4.x`            |
| [wodby/drupal-cms]    | [wodby/drupal-php]    | `8.3`                             |                  |
| [wodby/matomo]        | [wodby/php]           | `8.1`                             |                  |
| [wodby/webgrind]      | [wodby/php]           | `8.1`                             |                  |
| [wodby/wordpress-php] | [wodby/php]           | `8.5`, `8.4`, `8.3`, `8.2`, `8.1` | `4.x`            |
| [wodby/wordpress]     | [wodby/wordpress-php] | `8.5`, `8.4`, `8.3`, `8.2`, `8.1` | `4.x`            |
| [wodby/xhprof]        | [wodby/php]           | `8.1`                             |                  |
| [wodby/laravel-php]   | [wodby/php]           | `8.4`, `8.3`, `8.2`, `8.1`        |                  |

### Version updates from upstream other than the base image

- Minor/patch version updates
- New stability tag release

| Image                 | Upstream                     | Versions                                 | Stability branch |
|-----------------------|------------------------------|------------------------------------------|------------------|
| [wodby/adminer]       | [vrana/adminer]              | `5`                                      |                  |
| [wodby/cachet]        | [CachetHQ/Cachet]            | `2`                                      |                  |
| [wodby/drupal]        | [drupal]                     | `11`, `10`, `7`                          | `4.x`            |
| [wodby/drupal-cms]    | [drupal-cms]                 | `1`                                      |                  |
| [wodby/elasticsearch] | [elastic/elasticsearch]      | `7`                                      |                  |
| [wodby/kibana]        | [elastic/kibana]             | `7`                                      |                  |
| [wodby/mariadb]       | [mariadb]                    | `11.8`, `11.4`, `11.2`, `10.11`,  `10.6` |                  |
| [wodby/matomo]        | [matomo-org/matomo]          | `5`                                      |                  |
| [wodby/nginx]         | [nginx]                      | `1.29`, `1.28`                           |                  |
| [wodby/varnish]       | [varnishcache/varnish-cache] | `6.0`                                    |                  |
| [wodby/webgrind]      | [jokkedk/webgrind]           | `1`                                      |                  |
| [wodby/wordpress]     | [wordpress]                  | `6`                                      | `4.x`            |
| [wodby/xhprof]        | [longxinH/xhprof]            | `2`                                      |                  |
| [wodby/solr]          | [apache/solr]                | `9`                                      |                  |
| [wodby/zookeeper]     | [apache/zookeeper]           | `3.9`                                    |                  |

### Docker4X projects

Update images stability tags

| Project                  |
|--------------------------|
| [wodby/docker4drupal]    |
| [wodby/docker4php]       |
| [wodby/docker4python]    |
| [wodby/docker4ruby]      |
| [wodby/docker4wordpress] |
| [wodby/docker4laravel]   |

### Build templates

| Project                     | Versions |
|-----------------------------|----------|
| [wodby/drupal-vanilla]      | 11 10 7  |
| [wodby/wordpress-vanilla]   |          |
| [wodby/drupal-cms-template] | 1        |

Not automated:

- Adding new minor/major version
- Rebase to a new major Alpine version
- Switching the latest version
- New stability branches for major stability tags updates
- [wodby/opensmtpd] (installed from Alpine repository package)
- [wodby/adminer] not auto-updates for the base image (php:8.4-apache)

[adoptium/containers]: https://github.com/adoptium/containers

[alpine]: https://github.com/gliderlabs/docker-alpine

[CachetHQ/Cachet]: https://github.com/CachetHQ/Cachet

[drupal]: https://github.com/drupal/drupal

[drupal-cms]: https://git.drupalcode.org/project/cms

[elastic/elasticsearch]: https://github.com/elastic/elasticsearch

[elastic/kibana]: https://github.com/elastic/kibana

[httpd]: https://github.com/docker-library/httpd

[jokkedk/webgrind]: https://github.com/jokkedk/webgrind

[mariadb]: https://github.com/docker-library/mariadb

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

[varnishcache/varnish-cache]: https://github.com/varnishcache/varnish-cache

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

[_/postgres]: https://hub.docker.com/_/postgres

[_/php]: https://hub.docker.com/_/php

[valkey/valkey]: https://hub.docker.com/r/valkey/valkey

[wodby/cachet]: https://github.com/wodby/cachet

[wodby/docker4drupal]: https://github.com/wodby/docker4drupal

[wodby/docker4php]: https://github.com/wodby/docker4php

[wodby/docker4python]: https://github.com/wodby/docker4python

[wodby/docker4ruby]: https://github.com/wodby/docker4ruby

[wodby/docker4wordpress]: https://github.com/wodby/docker4wordpress

[wodby/docker4laravel]: https://github.com/wodby/docker4laravel

[wodby/drupal-php]: https://github.com/wodby/drupal-php

[wodby/drupal-cms-template]: https://github.com/wodby/drupal-cms-template

[wodby/drupal-vanilla]: https://github.com/wodby/drupal-vanilla

[wodby/wordpress-vanilla]: https://github.com/wodby/wordpress-vanilla

[wodby/laravel-php]: https://github.com/wodby/laravel-php

[wodby/drupal]: https://github.com/wodby/drupal

[wodby/drupal-cms]: https://github.com/wodby/drupal-cms

[wodby/elasticsearch]: https://github.com/wodby/elasticsearch

[_/httpd]: https://hub.docker.com/_/httpd

[wodby/kibana]: https://github.com/wodby/kibana

[wodby/mariadb]: https://github.com/wodby/mariadb

[wodby/matomo]: https://github.com/wodby/matomo

[wodby/memcached]: https://github.com/wodby/memcached

[wodby/nginx]: https://github.com/wodby/nginx

[wodby/node]: https://github.com/wodby/node

[wodby/openjdk]: https://github.com/wodby/openjdk

[wodby/opensmtpd]: https://github.com/wodby/opensmtpd

[wodby/php]: https://github.com/wodby/php

[wodby/postgres]: https://github.com/wodby/postgres

[wodby/python]: https://github.com/wodby/python

[wodby/valkey]: https://github.com/wodby/valkey

[wodby/redis]: https://github.com/wodby/redis

[wodby/ruby]: https://github.com/wodby/ruby

[wodby/varnish]: https://github.com/wodby/varnish

[wodby/webgrind]: https://github.com/wodby/webgrind

[wodby/wordpress-php]: https://github.com/wodby/wordpress-php

[wodby/wordpress]: https://github.com/wodby/wordpress

[wodby/xhprof]: https://github.com/wodby/xhprof

[wodby/squid]: https://github.com/wodby/squid

[wordpress]: https://github.com/WordPress/WordPress

