Dalli [![Tests](https://github.com/petergoldstein/dalli/actions/workflows/tests.yml/badge.svg)](https://github.com/petergoldstein/dalli/actions/workflows/tests.yml)
=====

Dalli is a high performance pure Ruby client for accessing memcached servers.  It works with memcached 1.4+ only as it uses the newer binary protocol.  It should be considered a replacement for the memcache-client gem.

The name is a variant of Salvador Dali for his famous painting [The Persistence of Memory](http://en.wikipedia.org/wiki/The_Persistence_of_Memory).

![Persistence of Memory](https://upload.wikimedia.org/wikipedia/en/d/dd/The_Persistence_of_Memory.jpg)

Dalli's initial development was sponsored by [CouchBase](http://www.couchbase.com/).  Many thanks to them!

Supported Ruby versions and implementations
------------------------------------------------

As of Dalli version 3.0 the following Ruby versions are supported:

 * Ruby 2.5.x, 2.6.x, 2.7.x, 3.0.x
 * JRuby 9.2.x, 9.3.x

If you have problems, please enter an issue.


Installation and Usage
------------------------

Remember, Dalli **requires** memcached 1.4+. You can check the version with `memcached -h`. Please note that the memcached version that *Mac OS X Snow Leopard* ships with is 1.2.8 and it won't work. Install the most recent version of memcached using Homebrew with

    brew install memcached

On Ubuntu you can install it by running:

    apt-get install memcached

You can verify your installation using this piece of code:

```bash
gem install dalli
```

```ruby
require 'dalli'
options = { namespace: "app_v1", compress: true }
dc = Dalli::Client.new('localhost:11211', options)
dc.set('abc', 123)
value = dc.get('abc')
```

With SSL enabled:
```ruby
require 'dalli'
ssl_context = OpenSSL::SSL::SSLContext.new
ssl_context.ca_file = "./myCA.pem"
ssl_context.ssl_version = :SSLv23
ssl_context.verify_hostname = true if ssl_context.respond_to?(:verify_hostname=)
ssl_context.verify_mode = OpenSSL::SSL::VERIFY_PEER

dc = Dalli::Client.new("memcached:11212", ssl_context: ssl_context)
dc.set("abc", 123)
value = dc.get("abc")
```

The test suite requires memcached 1.4.3+ with SASL enabled (`brew install memcached --enable-sasl ; mv /usr/bin/memcached /usr/bin/memcached.old`).  Currently only supports the PLAIN mechanism.

Dalli has no runtime dependencies.

Configuration
------------------------

**servers**: An Array of "host:port:weight" where weight allows you to distribute cache unevenly.

Dalli::Client accepts the following options. All times are in seconds.

**expires_in**: Global default for key TTL.  Default is 0, which means no expiry.

**namespace**: If specified, prepends each key with this value to provide simple namespacing.  Default is nil.

**failover**: Boolean, if true Dalli will failover to another server if the main server for a key is down.  Default is true.

**threadsafe**: Boolean.  If true Dalli ensures that only one thread is using a socket at a given time. Default is true. You can set to false if you are using the Client within a thread-safe connection pool.

**serializer**: The serializer to use for objects being stored (ex. JSON).
Default is Marshal.

**compress**: Boolean, if true Dalli will gzip-compress values larger than compression_min_size.  Can be overridden on a per-request basis. Default is true.

**compression_min_size**: Minimum value byte size for which to attempt compression. Default is 4K.

**compressor**: The compressor to use for objects being stored.
Default is zlib, implemented under `Dalli::Compressor`.
If serving compressed data using nginx's HttpMemcachedModule, set `memcached_gzip_flag 2` and use `Dalli::GzipCompressor`

**keepalive**: Boolean. If true, Dalli will enable keep-alive for socket connections.  Default is true.

**socket_timeout**: Timeout for all socket operations (connect, read, write). Default is 1.

**socket_max_failures**: When a socket operation fails after socket_timeout, the same operation is retried. This is to not immediately mark a server down when there's a very slight network problem. Default is 2.

**socket_failure_delay**: Before retrying a socket operation, the process sleeps for this amount of time. Default is 0.1.  Set to nil for no delay.

**down_retry_delay**: When a server has been marked down due to many failures, the server will be checked again for being alive only after this amount of time. Don't set this value too low, otherwise each request which tries the failed server might hang for the maximum **socket_timeout**. Default is 30 seconds.

**value_max_bytes**: The maximum size of a value in memcached.  Defaults to 1MB, this can be increased with memcached's -I parameter.  You must also configure Dalli to allow the larger size here.

**username**: The username to use for authenticating this client instance against a SASL-enabled memcached server.  Heroku users should not need to use this normally.

**password**: The password to use for authenticating this client instance against a SASL-enabled memcached server.  Heroku users should not need to use this normally.

**sndbuf**: In bytes, set the socket SO_SNDBUF. Defaults to operating system default.

**rcvbuf**: In bytes, set the socket SO_RCVBUF. Defaults to operating system default.

**cache_nils**: Boolean. If true Dalli will not treat cached `nil` values as 'not found' for `#fetch` operations. Default is false.

**raise_errors**: Boolean. When true DalliStore will reraise Dalli:DalliError instead swallowing the error. Default is false.

**instrument_errors**: Boolean. When true DalliStore will send notification of Dalli::DalliError via a 'cache_error.active_support' event. Default is false.

Features and Changes
------------------------

By default, Dalli is thread-safe. Disable thread-safety at your own peril.

Dalli does not need anything special in Unicorn/Passenger since 2.0.4.
It will detect sockets shared with child processes and gracefully reopen the
socket.

Note that Dalli does not require ActiveSupport or Rails.  You can safely use it in your own Ruby projects.

[View the Client API](http://www.rubydoc.info/github/mperham/dalli/Dalli/Client)

Helping Out
-------------

If you have a fix you wish to provide, please fork the code, fix in your local project and then send a pull request on github.  Please ensure that you include a test which verifies your fix and update `History.md` with a one sentence description of your fix so you get credit as a contributor.

We're not accepting new compressors. They are trivial to add in an initializer. See [#385](https://github.com/petergoldstein/dalli/pull/385) (LZ4), [#406](https://github.com/petergoldstein/dalli/pull/406) (Snappy)

Thanks
------------

Mike Perham - for originally authoring the Dalli project and serving as maintainer and primary contributor

Eric Wong - for help using his [kgio](http://bogomips.org/kgio/) library.

Brian Mitchell - for his remix-stash project which was helpful when implementing and testing the binary protocol support.

[CouchBase](http://couchbase.com) - for their project sponsorship

Authors
----------

* [Peter M. Goldstein](https://github.com/petergoldstein) - current maintainer
* [Mike Perham](https://github.com/mperham) and contributors


Copyright
-----------

Copyright (c) Mike Perham, Peter M. Goldstein. See LICENSE for details.
