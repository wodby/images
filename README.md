# Docker images auto updater

[![Build Status](https://travis-ci.com/wodby/images.svg?branch=master)](https://travis-ci.com/wodby/images)

## Auto-updated images

Forks:

| Image                 | Upstream  |
| --------------------- | --------- |
| [wodby/base-php]      | [php]     |
| [wodby/base-python]   | [python]  |
| [wodby/base-ruby]     | [ruby]    |
| [wodby/httpd]         | [httpd]   |
| [wodby/openjdk]       | [openjdk] |

Update versions from base docker images (patch updates only):

| Image                 | Upstream (base image) | Versions                                               |
| --------------------- | --------------------- | -----------------------------------------------        |
| [wodby/apache]        | [wodby/httpd]         | `2.4`                                                  |
| [wodby/memcached]     | [memcached]           | `1.5`                                                  |
| [wodby/node]          | [node]                | `10.9`, `8.11`, `6.14`                                 |
| [wodby/php]           | [wodby/base-php]      | `7.2`, `7.1`, `7.0`, `5.6`                             |
| [wodby/postgres]      | [postgres]            | `10`, `9.6`, `9.5`, `9.4`, `9.3`                       |
| [wodby/python]        | [wodby/base-python]   | `3.7`, `3.6`, `3.5`, `3.4`, `2.7`                      |
| [wodby/redis]         | [redis]               | `4.0`, `3.2`                                           |
| [wodby/ruby]          | [wodby/base-ruby]     | `2.5`, `2.4`, `2.3`                                    |
| [wodby/solr]          | [solr]                | `7.4`, `7.3`, `7.2`, `7.1`, `6.6`, `6.4`, `5.5`, `5.4` |

Rebuild against updated base image, rebase to newer stability tags, issuing new tags:

| Image                 | Upstream (base image) |
| --------------------- | --------------------- |
| [wodby/adminer]       | [wodby/php]           |
| [wodby/cachet]        | [wodby/php]           |
| [wodby/drupal-php]    | [wodby/php]           |
| [wodby/drupal]        | [wodby/drupal-php]    |
| [wodby/matomo]        | [wodby/php]           |
| [wodby/wordpress-php] | [wodby/php]           |
| [wodby/wordpress]     | [wodby/wordpress-php] |
| [wodby/webgrind]      | [wodby/php]           |

Vanilla updates:

| Image                 | Upstream                | Version                                         |
| --------------------- | ----------------------- | ----------------------------------------------- |
| [wodby/elasticsearch] | [elastic/elasticsearch] | `6.3`, `6.2`, `6.1`, `6.0`, `5.6`, `5.5`, `5.4` |
| [wodby/kibana]        | [elastic/kibana]        | `6.3`, `6.2`, `6.1`, `6.0`, `5.6`, `5.5`, `5.4` |
| [wodby/mariadb]       | [mariadb]               | `10.3`, `10.2`, `10.1`                          |
| [wodby/nginx]         | [nginx]                 | `1.15`, `1.14`, `1.13`                          |
| [wodby/adminer]       | [vrana/adminer]         | `4`                                             |
| [wodby/cachet]        | [CachetHQ/Cachet]       | `2`                                             |
| [wodby/drupal]        | [drupal]                | `8`, `7`                                        |
| [wodby/matomo]        | [matomo-org/matomo]     | `3`                                             |
| [wodby/webgrind]      | [jokkedk/webgrind]      | `1`                                             |
| [wodby/wordpress]     | [wordpress]             | `4`                                             |

Not automated:

* Adding new minor version, setting a new minor version as latest
* Java version for [wodby/elasticsearch] and [wodby/kibana]
* [wodby/alpine]
* [wodby/opensmtpd]
* [wodby/varnish]

`-//-` means same as the base image.

[CachetHQ/Cachet]: https://github.com/CachetHQ/Cachet
[drupal]: https://github.com/docker-library/drupal
[elastic/elasticsearch]: https://github.com/elastic/elasticsearch
[httpd]: https://github.com/docker-library/httpd
[jokkedk/webgrind]: https://github.com/jokkedk/webgrind
[elastic/kibana]: https://github.com/elastic/kibana
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
[vrana/adminer]: https://github.com/vrana/adminer
[wodby/adminer]: https://github.com/wodby/adminer
[wodby/alpine]: https://github.com/wodby/alpine
[wodby/apache]: https://github.com/wodby/apache
[wodby/base-php]: https://github.com/wodby/base-php
[wodby/base-python]: https://github.com/wodby/base-python
[wodby/base-ruby]: https://github.com/wodby/base-ruby
[wodby/cachet]: https://github.com/wodby/cachet
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
[wordpress]: https://github.com/docker-library/wordpress
