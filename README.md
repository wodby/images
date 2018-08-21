# Docker images auto updater

[![Build Status](https://travis-ci.com/wodby/images.svg?branch=master)](https://travis-ci.com/wodby/images)

## Auto-updated images

Generic usage images:

| Image                 | Base image            | Updates source          |
| --------------------- | --------------------- | ----------------------- |
| [wodby/apache]        | [wodby/httpd]         | -//-                    |
| [wodby/base-php]      | [wodby/alpine]        | [php]                   |
| [wodby/base-python]   | [wodby/alpine]        | [python]                |
| [wodby/base-ruby]     | [wodby/alpine]        | [ruby]                  |
| [wodby/drupal-php]    | [wodby/php]           | -//-                    |
| [wodby/elasticsearch] | [wodby/openjdk]       | [elastic/elasticsearch] |
| [wodby/httpd]         | [wodby/alpine]        | [httpd]                 |
| [wodby/kibana]        | [wodby/openjdk]       | [elastic/kibana]        |
| [wodby/mariadb]       | [wodby/alpine]        | [mariadb]               |
| [wodby/memcached]     | [memcached]           | -//-                    |
| [wodby/nginx]         | [wodby/alpine]        | [nginx]                 |
| [wodby/node]          | [node]                | -//-                    |
| [wodby/openjdk]       | [wodby/alpine]        | [openjdk]               |
| [wodby/php]           | [wodby/base-php]      | -//-                    |
| [wodby/postgres]      | [postgres]            | -//-                    |
| [wodby/python]        | [wodby/base-python]   | -//-                    |
| [wodby/redis]         | [redis]               | -//-                    |
| [wodby/ruby]          | [wodby/base-ruby]     | -//-                    |
| [wodby/solr]          | [solr]                | -//-                    |
| [wodby/wordpress-php] | [wodby/php]           | -//-                    |

Vanilla PHP-based images:

| Image                 | Base image (PHP updates) | Vanilla updates source |
| --------------------- | ------------------------ | ---------------------- |
| [wodby/adminer]       | [wodby/php]              | [vrana/adminer]        |
| [wodby/cachet]        | [wodby/php]              | [CachetHQ/Cachet]      |
| [wodby/drupal]        | [wodby/drupal-php]       | [drupal]               |
| [wodby/matomo]        | [wodby/php]              | [matomo-org/matomo]    |
| [wodby/webgrind]      | [wodby/php]              | [jokkedk/webgrind]     |
| [wodby/wordpress]     | [wodby/wordpress-php]    | [wordpress]            |

Manual updates:

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
