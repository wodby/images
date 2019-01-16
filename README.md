# Docker images auto updater

[![Build Status](https://travis-ci.com/wodby/images.svg?branch=master)](https://travis-ci.com/wodby/images)

## Auto-updated images

### Forks

Syncing with upstream.

| Image                 | Upstream  |
| --------------------- | --------- |
| [wodby/base-php]      | [php]     |
| [wodby/base-python]   | [python]  |
| [wodby/base-ruby]     | [ruby]    |
| [wodby/httpd]         | [httpd]   |
| [wodby/openjdk]       | [openjdk] |

### Alpine base image

| Image                 | Alpine version |
| --------------------- | -------------- |
| [wodby/base-php]      | `3.8`          |
| [wodby/base-python]   | `3.8`          |
| [wodby/base-ruby]     | `3.8`          |
| [wodby/httpd]         | `3.8`          |
| [wodby/openjdk]       | `3.8`          |
| [wodby/mariadb]       | `3.8`          |
| [wodby/varnish]       | `3.8`          |
| [wodby/nginx]         | `3.8`          |

### Images based on official images or their forks

* Patch version updates
* New stability tags release

| Image                 | Upstream (base image) | Versions                                                      |
| --------------------- | --------------------- | ------------------------------------------------------        |
| [wodby/alpine]        | [alpine]              | `3.8`, `3.7`, `3.6`                                           |
| [wodby/apache]        | [wodby/httpd]         | `2.4`                                                         |
| [wodby/memcached]     | [memcached]           | `1`                                                           |
| [wodby/node]          | [node]                | `10`, `8`, `6`                                                |
| [wodby/php]           | [wodby/base-php]      | `7.3`, `7.2`, `7.1`, `5.6`                                    |
| [wodby/postgres]      | [postgres]            | `11`, `10`, `9.6`, `9.5`, `9.4`, `9.3`                        |
| [wodby/python]        | [wodby/base-python]   | `3.7`, `3.6`, `3.5`, `3.4`, `2.7`                             |
| [wodby/redis]         | [redis]               | `5`, `4`                                                      |
| [wodby/ruby]          | [wodby/base-ruby]     | `2.5`, `2.4`, `2.3`                                           |
| [wodby/solr]          | [solr]                | `7.5`, `7.4`, `7.3`, `7.2`, `7.1`, `6.6`, `6.4`, `5.5`, `5.4` |

### Descendant images

* Rebuild against updated base image
* Rebase to newer stability tags
* New stability tags release

| Image                 | Upstream (base image) | Versions                   | Stability branch |
| --------------------- | --------------------- | -------------------        | --------------   |
| [wodby/adminer]       | [wodby/php]           | `7.1`                      | `2.x`            |
| [wodby/cachet]        | [wodby/php]           | `7.1`                      | `1.x`            |
| [wodby/drupal-php]    | [wodby/php]           | `7.3`, `7.2`, `7.1`, `5.6` | `4.x`            |
| [wodby/drupal]        | [wodby/drupal-php]    | `7.3`, `7.2`, `7.1`, `5.6` | `4.x`            |
| [wodby/matomo]        | [wodby/php]           | `7.1`                      | `1.x`            |
| [wodby/wordpress-php] | [wodby/php]           | `7.3`, `7.2`, `7.1`, `5.6` | `4.x`            |
| [wodby/wordpress]     | [wodby/wordpress-php] | `7.3`, `7.2`, `7.1`, `5.6` | `4.x`            |
| [wodby/webgrind]      | [wodby/php]           | `7.1`                      | `1.x`            |
| [wodby/xhprof]        | [wodby/php]           | `7.1`                      | `1.x`            |

### Version updates from upstream other than base image

* Minor and patch version updates
* New stability tags release

| Image                 | Upstream                     | Versions                                        | Stability branch |
| --------------------- | -----------------------      | ----------------------------------------------- | --------------   |
| [wodby/elasticsearch] | [elastic/elasticsearch]      | `6.3`, `6.2`, `6.1`, `6.0`, `5.6`, `5.5`, `5.4` |                  |
| [wodby/kibana]        | [elastic/kibana]             | `6.3`, `6.2`, `6.1`, `6.0`, `5.6`, `5.5`, `5.4` |                  |
| [wodby/mariadb]       | [mariadb]                    | `10.3`, `10.2`, `10.1`                          |                  |
| [wodby/nginx]         | [nginx]                      | `1.15`, `1.14`, `1.13`                          |                  |
| [wodby/adminer]       | [vrana/adminer]              | `4`                                             | `2.x`            |
| [wodby/cachet]        | [CachetHQ/Cachet]            | `2`                                             | `1.x`            |
| [wodby/drupal]        | [drupal]                     | `8`, `7`                                        | `4.x`            |
| [wodby/matomo]        | [matomo-org/matomo]          | `3`                                             | `1.x`            |
| [wodby/varnish]       | [varnishcache/varnish-cache] | `6.0`, `4.1`                                    |                  |
| [wodby/webgrind]      | [jokkedk/webgrind]           | `1`                                             | `1.x`            |
| [wodby/wordpress]     | [wordpress]                  | `5`                                             | `4.x`            |

### Docker4X projects

Update images stability tags

| Project                  |
| ------------------------ |
| [wodby/docker4drupal]    |
| [wodby/docker4php]       |
| [wodby/docker4python]    |
| [wodby/docker4ruby]      |
| [wodby/docker4wordpress] |

Not automated:

* Adding new minor/major version
* Rebase to a new minor Alpine version
* Switch latest version
* New stability branches for major stability tags updates
* Java version for [wodby/elasticsearch] and [wodby/kibana]
* Config set updates from Search API Solr module for [wodby/solr]
* [wodby/opensmtpd] (from Alpine repository)

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
[openjdk]: https://github.com/docker-library/openjdk
[php]: https://github.com/docker-library/php
[postgres]: https://github.com/docker-library/postgres
[python]: https://github.com/docker-library/python
[redis]: https://github.com/docker-library/redis
[ruby]: https://github.com/docker-library/ruby
[solr]: https://github.com/docker-library/solr
[varnishcache/varnish-cache]: https://github.com/varnishcache/varnish-cache
[vrana/adminer]: https://github.com/vrana/adminer
[wodby/adminer]: https://github.com/wodby/adminer
[wodby/alpine]: https://github.com/wodby/alpine
[wodby/apache]: https://github.com/wodby/apache
[wodby/base-php]: https://github.com/wodby/base-php
[wodby/base-python]: https://github.com/wodby/base-python
[wodby/base-ruby]: https://github.com/wodby/base-ruby
[wodby/cachet]: https://github.com/wodby/cachet
[wodby/docker4drupal]: https://github.com/wodby/docker4drupal
[wodby/docker4php]: https://github.com/wodby/docker4php
[wodby/docker4python]: https://github.com/wodby/docker4python
[wodby/docker4ruby]: https://github.com/wodby/docker4ruby
[wodby/docker4wordpress]: https://github.com/wodby/docker4wordpress
[wodby/drupal-php]: https://github.com/wodby/drupal-php
[wodby/drupal]: https://github.com/wodby/drupal
[wodby/elasticsearch]: https://github.com/wodby/elasticsearch
[wodby/httpd]: https://github.com/wodby/httpd
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
[wodby/redis]: https://github.com/wodby/redis
[wodby/ruby]: https://github.com/wodby/ruby
[wodby/solr]: https://github.com/wodby/solr
[wodby/varnish]: https://github.com/wodby/varnish
[wodby/webgrind]: https://github.com/wodby/webgrind
[wodby/wordpress-php]: https://github.com/wodby/wordpress-php
[wodby/wordpress]: https://github.com/wodby/wordpress
[wodby/xhprof]: https://github.com/wodby/xhprof
[wordpress]: https://github.com/WordPress/WordPress
