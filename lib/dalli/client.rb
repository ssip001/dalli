# frozen_string_literal: true

require "digest/md5"
require "set"

# encoding: ascii
module Dalli
  class Client
    ##
    # Dalli::Client is the main class which developers will use to interact with
    # the memcached server.  Usage:
    #
    #   Dalli::Client.new(['localhost:11211:10', 'cache-2.example.com:11211:5', '192.168.0.1:22122:5', '/var/run/memcached/socket'],
    #                   :threadsafe => true, :failover => true, :expires_in => 300)
    #
    # servers is an Array of "host:port:weight" where weight allows you to distribute cache unevenly.
    # Both weight and port are optional.  If you pass in nil, Dalli will use the <tt>MEMCACHE_SERVERS</tt>
    # environment variable or default to 'localhost:11211' if it is not present.  Dalli also supports
    # the ability to connect to Memcached on localhost through a UNIX socket.  To use this functionality,
    # use a full pathname (beginning with a slash character '/') in place of the "host:port" pair in
    # the server configuration.
    #
    # Options:
    # - :namespace - prepend each key with this value to provide simple namespacing.
    # - :failover - if a server is down, look for and store values on another server in the ring.  Default: true.
    # - :threadsafe - ensure that only one thread is actively using a socket at a time. Default: true.
    # - :expires_in - default TTL in seconds if you do not pass TTL as a parameter to an individual operation, defaults to 0 or forever
    # - :compress - if true Dalli will compress values larger than compression_min_size bytes before sending them to memcached.  Default: true.
    # - :compression_min_size - the minimum size (in bytes) for which Dalli will compress values sent to Memcached.  Defaults to 4K.
    # - :serializer - defaults to Marshal
    # - :compressor - defaults to zlib
    # - :cache_nils - defaults to false, if true Dalli will not treat cached nil values as 'not found' for #fetch operations.
    # - :digest_class - defaults to Digest::MD5, allows you to pass in an object that responds to the hexdigest method, useful for injecting a FIPS compliant hash object.
    # - :protocol_implementation - defaults to Dalli::Protocol::Binary which uses the binary protocol. Allows you to pass an alternative implementation using another protocol.
    #
    def initialize(servers = nil, options = {})
      validate_servers_arg(servers)
      @servers = normalize_servers(servers || ENV["MEMCACHE_SERVERS"] || "127.0.0.1:11211")
      @options = normalize_options(options)
      @ring = nil
    end

    #
    # The standard memcached instruction set
    #

    ##
    # Turn on quiet aka noreply support.
    # All relevant operations within this block will be effectively
    # pipelined as Dalli will use 'quiet' operations where possible.
    # Currently supports the set, add, replace and delete operations.
    def multi
      old, Thread.current[:dalli_multi] = Thread.current[:dalli_multi], true
      yield
    ensure
      Thread.current[:dalli_multi] = old
    end

    ##
    # Get the value associated with the key.
    # If a value is not found, then +nil+ is returned.
    def get(key, options = nil)
      perform(:get, key, options)
    end

    ##
    # Fetch multiple keys efficiently.
    # If a block is given, yields key/value pairs one at a time.
    # Otherwise returns a hash of { 'key' => 'value', 'key2' => 'value1' }
    def get_multi(*keys)
      keys.flatten!
      keys.compact!

      return {} if keys.empty?
      if block_given?
        get_multi_yielder(keys) { |k, data| yield k, data.first }
      else
        {}.tap do |hash|
          get_multi_yielder(keys) { |k, data| hash[k] = data.first }
        end
      end
    end

    CACHE_NILS = {cache_nils: true}.freeze

    # Fetch the value associated with the key.
    # If a value is found, then it is returned.
    #
    # If a value is not found and no block is given, then nil is returned.
    #
    # If a value is not found (or if the found value is nil and :cache_nils is false)
    # and a block is given, the block will be invoked and its return value
    # written to the cache and returned.
    def fetch(key, ttl = nil, options = nil)
      options = options.nil? ? CACHE_NILS : options.merge(CACHE_NILS) if @options[:cache_nils]
      val = get(key, options)
      not_found = @options[:cache_nils] ?
        val == Dalli::Protocol::NOT_FOUND :
        val.nil?
      if not_found && block_given?
        val = yield
        add(key, val, ttl_or_default(ttl), options)
      end
      val
    end

    ##
    # compare and swap values using optimistic locking.
    # Fetch the existing value for key.
    # If it exists, yield the value to the block.
    # Add the block's return value as the new value for the key.
    # Add will fail if someone else changed the value.
    #
    # Returns:
    # - nil if the key did not exist.
    # - false if the value was changed by someone else.
    # - true if the value was successfully updated.
    def cas(key, ttl = nil, options = nil, &block)
      cas_core(key, false, ttl, options, &block)
    end

    ##
    # like #cas, but will yield to the block whether or not the value
    # already exists.
    #
    # Returns:
    # - false if the value was changed by someone else.
    # - true if the value was successfully updated.
    def cas!(key, ttl = nil, options = nil, &block)
      cas_core(key, true, ttl, options, &block)
    end

    def set(key, value, ttl = nil, options = nil)
      perform(:set, key, value, ttl_or_default(ttl), 0, options)
    end

    ##
    # Conditionally add a key/value pair, if the key does not already exist
    # on the server.  Returns truthy if the operation succeeded.
    def add(key, value, ttl = nil, options = nil)
      perform(:add, key, value, ttl_or_default(ttl), options)
    end

    ##
    # Conditionally add a key/value pair, only if the key already exists
    # on the server.  Returns truthy if the operation succeeded.
    def replace(key, value, ttl = nil, options = nil)
      perform(:replace, key, value, ttl_or_default(ttl), 0, options)
    end

    def delete(key)
      perform(:delete, key, 0)
    end

    ##
    # Append value to the value already stored on the server for 'key'.
    # Appending only works for values stored with :raw => true.
    def append(key, value)
      perform(:append, key, value.to_s)
    end

    ##
    # Prepend value to the value already stored on the server for 'key'.
    # Prepending only works for values stored with :raw => true.
    def prepend(key, value)
      perform(:prepend, key, value.to_s)
    end

    def flush(delay = 0)
      time = -delay
      ring.servers.map { |s| s.request(:flush, time += delay) }
    end

    alias_method :flush_all, :flush

    ##
    # Incr adds the given amount to the counter on the memcached server.
    # Amt must be a positive integer value.
    #
    # If default is nil, the counter must already exist or the operation
    # will fail and will return nil.  Otherwise this method will return
    # the new value for the counter.
    #
    # Note that the ttl will only apply if the counter does not already
    # exist.  To increase an existing counter and update its TTL, use
    # #cas.
    def incr(key, amt = 1, ttl = nil, default = nil)
      raise ArgumentError, "Positive values only: #{amt}" if amt < 0
      perform(:incr, key, amt.to_i, ttl_or_default(ttl), default)
    end

    ##
    # Decr subtracts the given amount from the counter on the memcached server.
    # Amt must be a positive integer value.
    #
    # memcached counters are unsigned and cannot hold negative values.  Calling
    # decr on a counter which is 0 will just return 0.
    #
    # If default is nil, the counter must already exist or the operation
    # will fail and will return nil.  Otherwise this method will return
    # the new value for the counter.
    #
    # Note that the ttl will only apply if the counter does not already
    # exist.  To decrease an existing counter and update its TTL, use
    # #cas.
    def decr(key, amt = 1, ttl = nil, default = nil)
      raise ArgumentError, "Positive values only: #{amt}" if amt < 0
      perform(:decr, key, amt.to_i, ttl_or_default(ttl), default)
    end

    ##
    # Touch updates expiration time for a given key.
    #
    # Returns true if key exists, otherwise nil.
    def touch(key, ttl = nil)
      resp = perform(:touch, key, ttl_or_default(ttl))
      resp.nil? ? nil : true
    end

    ##
    # Gat (get and touch) fetch an item and simultaneously update its expiration time.
    #
    # If a value is not found, then +nil+ is returned.
    def gat(key, ttl = nil)
      perform(:gat, key, ttl_or_default(ttl))
    end

    ##
    # Collect the stats for each server.
    # You can optionally pass a type including :items, :slabs or :settings to get specific stats
    # Returns a hash like { 'hostname:port' => { 'stat1' => 'value1', ... }, 'hostname2:port' => { ... } }
    def stats(type = nil)
      type = nil unless [nil, :items, :slabs, :settings].include? type
      values = {}
      ring.servers.each do |server|
        values[server.name.to_s] = server.alive? ? server.request(:stats, type.to_s) : nil
      end
      values
    end

    ##
    # Reset stats for each server.
    def reset_stats
      ring.servers.map do |server|
        server.alive? ? server.request(:reset_stats) : nil
      end
    end

    ##
    ## Make sure memcache servers are alive, or raise an Dalli::RingError
    def alive!
      ring.server_for_key("")
    end

    ##
    ## Version of the memcache servers.
    def version
      values = {}
      ring.servers.each do |server|
        values[server.name.to_s] = server.alive? ? server.request(:version) : nil
      end
      values
    end

    ##
    # Get the value and CAS ID associated with the key.  If a block is provided,
    # value and CAS will be passed to the block.
    def get_cas(key)
      (value, cas) = perform(:cas, key)
      value = !value || value == "Not found" ? nil : value
      if block_given?
        yield value, cas
      else
        [value, cas]
      end
    end

    ##
    # Fetch multiple keys efficiently, including available metadata such as CAS.
    # If a block is given, yields key/data pairs one a time.  Data is an array:
    # [value, cas_id]
    # If no block is given, returns a hash of
    #   { 'key' => [value, cas_id] }
    def get_multi_cas(*keys)
      if block_given?
        get_multi_yielder(keys) { |*args| yield(*args) }
      else
        {}.tap do |hash|
          get_multi_yielder(keys) { |k, data| hash[k] = data }
        end
      end
    end

    ##
    # Set the key-value pair, verifying existing CAS.
    # Returns the resulting CAS value if succeeded, and falsy otherwise.
    def set_cas(key, value, cas, ttl = nil, options = nil)
      ttl ||= @options[:expires_in].to_i
      perform(:set, key, value, ttl, cas, options)
    end

    ##
    # Conditionally add a key/value pair, verifying existing CAS, only if the
    # key already exists on the server.  Returns the new CAS value if the
    # operation succeeded, or falsy otherwise.
    def replace_cas(key, value, cas, ttl = nil, options = nil)
      ttl ||= @options[:expires_in].to_i
      perform(:replace, key, value, ttl, cas, options)
    end

    # Delete a key/value pair, verifying existing CAS.
    # Returns true if succeeded, and falsy otherwise.
    def delete_cas(key, cas = 0)
      perform(:delete, key, cas)
    end

    ##
    # Close our connection to each server.
    # If you perform another operation after this, the connections will be re-established.
    def close
      if @ring
        @ring.servers.each { |s| s.close }
        @ring = nil
      end
    end
    alias_method :reset, :close

    # Stub method so a bare Dalli client can pretend to be a connection pool.
    def with
      yield self
    end

    private

    def cas_core(key, always_set, ttl = nil, options = nil)
      (value, cas) = perform(:cas, key)
      value = !value || value == "Not found" ? nil : value
      return if value.nil? && !always_set
      newvalue = yield(value)
      perform(:set, key, newvalue, ttl_or_default(ttl), cas, options)
    end

    def ttl_or_default(ttl)
      (ttl || @options[:expires_in]).to_i
    rescue NoMethodError
      raise ArgumentError, "Cannot convert ttl (#{ttl}) to an integer"
    end

    def groups_for_keys(*keys)
      keys.flatten!
      keys.map! { |a| validate_key(a.to_s) }

      keys.group_by { |key|
        begin
          ring.server_for_key(key)
        rescue Dalli::RingError
          Dalli.logger.debug { "unable to get key #{key}" }
          nil
        end
      }
    end

    def make_multi_get_requests(groups)
      groups.each do |server, keys_for_server|
        # TODO: do this with the perform chokepoint?
        # But given the fact that fetching the response doesn't take place
        # in that slot it's misleading anyway. Need to move all of this method
        # into perform to be meaningful
        server.request(:send_multiget, keys_for_server)
      rescue DalliError, NetworkError => e
        Dalli.logger.debug { e.inspect }
        Dalli.logger.debug { "unable to get keys for server #{server.name}" }
      end
    end

    def perform_multi_response_start(servers)
      deleted = []
  
      servers.each do |server|
        next unless server.alive?
  
        begin
          server.multi_response_start
        rescue Dalli::NetworkError
          servers.each { |s| s.multi_response_abort unless s.sock.nil?  }
          raise
        rescue Dalli::DalliError => e
          Dalli.logger.debug { e.inspect }
          Dalli.logger.debug { "results from this server will be missing" }
          deleted.append(server)
        end
      end
  
      servers.delete_if { |server| deleted.include?(server) }
    end

    ##
    # Ensures that the servers arg is either an array or a string.
    def validate_servers_arg(servers)
      return if servers.nil?
      return if servers.is_a?(Array)
      return if servers.is_a?(String)

      raise ArgumentError, "An explicit servers argument must be a comma separated string or an array containing strings."
    end

    ##
    # Normalizes the argument into an array of servers.
    # If the argument is a string, or an array containing strings, it's expected that the URIs are comma separated e.g.
    # "memcache1.example.com:11211,memcache2.example.com:11211,memcache3.example.com:11211"
    def normalize_servers(servers)
      Array(servers).flat_map do |server|
        if server.is_a? String
          server.split(",")
        else
          server
        end
      end
    end

    def ring
      @ring ||= Dalli::Ring.new(
        @servers.map { |s|
          server_options = {}
          if s.start_with?("memcached://")
            uri = URI.parse(s)
            server_options[:username] = uri.user
            server_options[:password] = uri.password
            s = "#{uri.host}:#{uri.port}"
          end
          @options.fetch(:protocol_implementation, Dalli::Protocol::Binary).new(s, @options.merge(server_options))
        }, @options
      )
    end

    # Chokepoint method for instrumentation
    def perform(*all_args)
      begin
        return yield if block_given?
        op, key, *args = all_args

        key = key.to_s
        key = validate_key(key)
      
        server = ring.server_for_key(key)
        server.request(op, key, *args)
      rescue NetworkError => e
        Dalli.logger.debug { e.inspect }
        Dalli.logger.debug { "retrying request with new server" }
        retry
      end
    end

    def validate_key(key)
      raise ArgumentError, "key cannot be blank" if !key || key.length == 0
      key = key_with_namespace(key)
      if key.length > 250
        digest_class = @options[:digest_class] || ::Digest::MD5
        max_length_before_namespace = 212 - (namespace || "").size
        key = "#{key[0, max_length_before_namespace]}:md5:#{digest_class.hexdigest(key)}"
      end
      key
    end

    def key_with_namespace(key)
      (ns = namespace) ? "#{ns}:#{key}" : key
    end

    def key_without_namespace(key)
      (ns = namespace) ? key.sub(%r{\A#{Regexp.escape ns}:}, "") : key
    end

    def namespace
      return nil unless @options[:namespace]
      @options[:namespace].is_a?(Proc) ? @options[:namespace].call.to_s : @options[:namespace].to_s
    end

    def normalize_options(opts)
      if opts[:compression]
        Dalli.logger.warn "DEPRECATED: Dalli's :compression option is now just :compress => true.  Please update your configuration."
        opts[:compress] = opts.delete(:compression)
      end
      begin
        opts[:expires_in] = opts[:expires_in].to_i if opts[:expires_in]
      rescue NoMethodError
        raise ArgumentError, "cannot convert :expires_in => #{opts[:expires_in].inspect} to an integer"
      end
      if opts[:digest_class] && !opts[:digest_class].respond_to?(:hexdigest)
        raise ArgumentError, "The digest_class object must respond to the hexdigest method"
      end
      opts
    end

    ##
    # Yields, one at a time, keys and their values+attributes.
    def get_multi_yielder(keys)
      perform do
        return {} if keys.empty?
        ring.lock do
          groups = groups_for_keys(keys)
          if (unfound_keys = groups.delete(nil))
            Dalli.logger.debug { "unable to get keys for #{unfound_keys.length} keys because no matching server was found" }
          end
          make_multi_get_requests(groups)

          servers = groups.keys
          return if servers.empty?
          servers = perform_multi_response_start(servers)

          start = Time.now
          loop do
            # remove any dead servers
            servers.delete_if { |s| s.sock.nil? }
            break if servers.empty?

            # calculate remaining timeout
            elapsed = Time.now - start
            timeout = servers.first.options[:socket_timeout]
            time_left = elapsed > timeout ? 0 : timeout - elapsed

            sockets = servers.map(&:sock)
            readable, _ = IO.select(sockets, nil, nil, time_left)

            if readable.nil?
              # no response within timeout; abort pending connections
              servers.each do |server|
                Dalli.logger.debug { "memcached at #{server.name} did not response within timeout" }
                server.multi_response_abort
              end
              break

            else
              readable.each do |sock|
                server = sock.server

                begin
                  server.multi_response_nonblock.each_pair do |key, value_list|
                    yield key_without_namespace(key), value_list
                  end

                  if server.multi_response_completed?
                    servers.delete(server)
                  end
                rescue NetworkError
                  servers.each { |s| s.multi_response_abort unless s.sock.nil? }
                  raise
                end
              end
            end
          end
        end
      end
    end

  end
end
