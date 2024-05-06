# Docker images auto updater

[![Build Status](https://github.com/wodby/images/workflows/Update/badge.svg)](https://github.com/wodby/images/actions)

## Auto-updated images

### Alpine-based images

| Image             | Alpine version |
|-------------------|----------------|
| [wodby/mariadb]   | `3.18`, `3.16` |
| [wodby/nginx]     | `3.19`         |
| [wodby/opensmtpd] | `3.18`         |
| [wodby/varnish]   | `3.18`         |
| [wodby/squid]     | `3.17`         |

### Images based on official images (or forks)

- Minor/patch version update
- Rebuild against updated base image
- New stability tag release on version update
- New stability tag release on Alpine Linux update

| Image             | Upstream (base image) | Versions                             |
|-------------------|-----------------------|--------------------------------------|
| [wodby/alpine]    | [alpine]              | `3.19`, `3.18`, `3.17`, `3.16`       |
| [wodby/apache]    | [_/httpd]             | `2.4`                                |
| [wodby/memcached] | [_/memcached]         | `1`                                  |
| [wodby/node]      | [node]                | `20`, `18`                           |
| [wodby/php]       | [_/php]               | `8.3`, `8.2`, `8.1`                  |
| [wodby/postgres]  | [_/postgres]          | `16`, `15`, `14`, `13`, `12`         |
| [wodby/python]    | [python]              | `3.12`, `3.11`, `3.10`, `3.9`, `3.8` |
| [wodby/valkey]    | [valkey/valkey]       | `7`                                  |
| [wodby/ruby]      | [ruby]                | `3.3`, `3.2`, `3.1`, `3.0`           |

### Descendant images

- Rebuild against updated base image
- Rebase to newer stability tag
- New stability tag release

| Image                 | Upstream (base image) | Versions            | Stability branch |
|-----------------------|-----------------------|---------------------|------------------|
| [wodby/adminer]       | [wodby/php]           | `7.4`               |                  |
| [wodby/drupal-php]    | [wodby/php]           | `8.3`, `8.2`, `8.1` | `4.x`            |
| [wodby/drupal]        | [wodby/drupal-php]    | `8.3`, `8.2`, `8.1` | `4.x`            |
| [wodby/matomo]        | [wodby/php]           | `8.1`               |                  |
| [wodby/webgrind]      | [wodby/php]           | `7.4`               |                  |
| [wodby/wordpress-php] | [wodby/php]           | `8.3`, `8.2`, `8.1` | `4.x`            |
| [wodby/wordpress]     | [wodby/wordpress-php] | `8.3`, `8.2`, `8.1` | `4.x`            |
| [wodby/xhprof]        | [wodby/php]           | `7.4`               |                  |
| [wodby/laravel-php]   | [wodby/php]           | `8.3`, `8.2`, `8.1` |                  |

### Version updates from upstream other than base image

- Minor/patch version updates
- New stability tag release

| Image                 | Upstream                     | Versions                                                 | Stability branch |
|-----------------------|------------------------------|----------------------------------------------------------|------------------|
| [wodby/adminer]       | [vrana/adminer]              | `4`                                                      |                  |
| [wodby/cachet]        | [CachetHQ/Cachet]            | `2`                                                      |                  |
| [wodby/drupal]        | [drupal]                     | `10`, `7`                                                | `4.x`            |
| [wodby/elasticsearch] | [elastic/elasticsearch]      | `7`                                                      |                  |
| [wodby/kibana]        | [elastic/kibana]             | `7`                                                      |                  |
| [wodby/mariadb]       | [mariadb]                    | `11.2`, `11.1`, `11.0`, `10.11`,  `10.6`, `10.5`, `10.4` |                  |
| [wodby/matomo]        | [matomo-org/matomo]          | `5`                                                      |                  |
| [wodby/nginx]         | [nginx]                      | `1.26`, `1.25`                                           |                  |
| [wodby/varnish]       | [varnishcache/varnish-cache] | `6.0`                                                    |                  |
| [wodby/webgrind]      | [jokkedk/webgrind]           | `1`                                                      |                  |
| [wodby/wordpress]     | [wordpress]                  | `6`                                                      | `4.x`            |
| [wodby/xhprof]        | [longxinH/xhprof]            | `2`                                                      |                  |

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

Not automated:

- Adding new minor/major version
- Rebase to a new major Alpine version
- Switching the latest version
- New stability branches for major stability tags updates
- [wodby/opensmtpd] (installed from Alpine repository package)

[adoptium/containers]: https://github.com/adoptium/containers

[alpine]: https://github.com/gliderlabs/docker-alpine

[CachetHQ/Cachet]: https://github.com/CachetHQ/Cachet

[drupal]: https://github.com/drupal/drupal

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

[ruby]: https://github.com/docker-library/ruby

[varnishcache/varnish-cache]: https://github.com/varnishcache/varnish-cache

[vrana/adminer]: https://github.com/vrana/adminer

[longxinH/xhprof]: https://github.com/longxinH/xhprof

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

[wodby/laravel-php]: https://github.com/wodby/laravel-php

[wodby/drupal]: https://github.com/wodby/drupal

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

[wodby/ruby]: https://github.com/wodby/ruby

[wodby/varnish]: https://github.com/wodby/varnish

[wodby/webgrind]: https://github.com/wodby/webgrind

[wodby/wordpress-php]: https://github.com/wodby/wordpress-php

[wodby/wordpress]: https://github.com/wodby/wordpress

[wodby/xhprof]: https://github.com/wodby/xhprof

[wodby/squid]: https://github.com/wodby/squid

[wordpress]: https://github.com/WordPress/WordPress
