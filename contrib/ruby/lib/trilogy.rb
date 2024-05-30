# frozen_string_literal: true

require "trilogy/version"
require "trilogy/error"
require "trilogy/result"
require "trilogy/cext"
require "trilogy/encoding"

require "socket"
require "io/nonblock"

class Trilogy
  DEFAULT_HOSTNAME = "127.0.0.1"
  DEFAULT_PORT = 3306
  SUPPORTS_RESOLV_TIMEOUT = Socket.method(:tcp).parameters.any? { |p| p.last == :resolv_timeout }

  def initialize(options = {})
    options = options.dup
    options[:host] = DEFAULT_HOSTNAME if !options[:host] && !options[:path]
    options[:port] = options[:port].to_i if options[:port]
    mysql_encoding = options[:encoding] || "utf8mb4"
    encoding = Trilogy::Encoding.find(mysql_encoding)
    charset = Trilogy::Encoding.charset(mysql_encoding)
    @connection_options = options
    @connected_host = nil

    begin
      @io = if options[:host]
        # TODO: Use Socket.new to set sockopts before connect?
        sock = if SUPPORTS_RESOLV_TIMEOUT
          Socket.tcp(
            options[:host],
            options.fetch(:port, DEFAULT_PORT),
            connect_timeout: options[:connect_timeout],
            resolv_timeout: @connect_timeout,
          )
        else
          Socket.tcp(
            options[:host],
            options.fetch(:port, DEFAULT_PORT),
            connect_timeout: options[:connect_timeout],
          )
        end
        sock.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, true)
        sock
      else
        UNIXSocket.new(options[:path])
      end
    rescue Errno::ECONNREFUSED => error
      raise Trilogy::BaseConnectionError, error.message
    rescue Socket::ResolutionError
      raise Trilogy::BaseConnectionError, "trilogy_connect - unable to connect to #{options[:host]}:#{options[:port]}: TRILOGY_DNS_ERROR"
    rescue Errno::ETIMEDOUT => error
      raise Trilogy::TimeoutError, error.message
    end

    if options.fetch(:keepalive_enabled, true)
      @io.setsockopt(Socket::SOL_SOCKET, Socket::SO_KEEPALIVE, true)
      if options[:keepalive_idle] && defined?(Socket::TCP_KEEPIDLE)
        @io.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_KEEPIDLE, options[:keepalive_idle])
      end

      if options[:keepalive_interval] && defined?(Socket::TCP_KEEPINTVL)
        @io.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_KEEPINTVL, options[:keepalive_interval])
      end

      if options[:keepalive_count] && defined?(Socket::TCP_KEEPCNT)
        @io.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_KEEPCNT, options[:keepalive_count])
      end
    end

    @io.nonblock = true

    _connect(@io.fileno, encoding, charset, options)
  end

  def connection_options
    @connection_options.dup.freeze
  end

  def in_transaction?
    (server_status & SERVER_STATUS_IN_TRANS) != 0
  end

  def server_info
    version_str = server_version

    if /\A(\d+)\.(\d+)\.(\d+)/ =~ version_str
      version_num = ($1.to_i * 10000) + ($2.to_i * 100) + $3.to_i
    end

    { :version => version_str, :id => version_num }
  end

  def connected_host
    @connected_host ||= query_with_flags("select @@hostname", query_flags | QUERY_FLAGS_FLATTEN_ROWS).rows.first
  end

  def query_with_flags(sql, flags)
    old_flags = query_flags
    self.query_flags = flags

    query(sql)
  ensure
    self.query_flags = old_flags
  end
end
