# frozen_string_literal: true

require "logger"

module AppsPatrol
  class Configuration
    # The app's ingest key. Without it every call is a no-op.
    attr_accessor :api_key
    # Address of your Apps Patrol instance.
    attr_accessor :base_url
    # false turns every call into a no-op (for example outside production).
    attr_accessor :enabled
    # Where problems are reported. Defaults to Rails.logger under Rails.
    attr_accessor :logger
    # Called as on_error.call(error, context) for anything that could not be sent.
    attr_accessor :on_error
    # Send automatically when this many items are waiting (at most 100).
    attr_accessor :batch_size
    # Send automatically at least this often, in seconds.
    attr_accessor :flush_interval
    # Items kept in memory while the server is unreachable; the oldest are dropped beyond this.
    attr_accessor :max_queue
    # Attempts per request for network errors, 5xx and rate limiting.
    attr_accessor :max_retries
    # Seconds allowed to connect, and to wait for a response.
    attr_accessor :open_timeout, :read_timeout
    # Under Rails: send app_opened once per shop per day from authenticated Shopify controllers.
    attr_accessor :auto_app_opened
    # Sends requests. Replace to route through a proxy or in tests.
    attr_accessor :transport

    def initialize
      @api_key = ENV["APPS_PATROL_KEY"]
      @base_url = ENV["APPS_PATROL_URL"] || "http://localhost:3000"
      @enabled = true
      @logger = Logger.new($stderr, level: Logger::WARN)
      @on_error = nil
      @batch_size = 100
      @flush_interval = 2
      @max_queue = 10_000
      @max_retries = 5
      @open_timeout = 3
      @read_timeout = 5
      @auto_app_opened = true
      @transport = nil
    end

    def active?
      enabled && !api_key.to_s.empty?
    end
  end
end
