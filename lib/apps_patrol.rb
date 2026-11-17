# frozen_string_literal: true

require "json"
require "securerandom"
require "time"

require_relative "apps_patrol/version"
require_relative "apps_patrol/configuration"
require_relative "apps_patrol/transport"
require_relative "apps_patrol/client"

# Sends usage events and shop profiles from a Shopify app to Apps Patrol.
#
#   AppsPatrol.configure { |c| c.api_key = ENV["APPS_PATROL_KEY"] }
#   AppsPatrol.track(shop: "store.myshopify.com", event: "feature_used", properties: { feature: "bulk_edit" })
#
# Calls return immediately: events are queued and sent in batches by a
# background thread. Nothing here raises into, or blocks, the host app.
module AppsPatrol
  # Raised only by AppsPatrol.ping, which exists to surface setup problems.
  class Error < StandardError
    attr_reader :code, :status

    def initialize(message, code: nil, status: nil)
      super(message)
      @code = code
      @status = status
    end
  end

  # Names with a meaning in Apps Patrol. Any other name is accepted too.
  STANDARD_EVENTS = %w[
    app_opened onboarding_started onboarding_completed feature_used
    plan_viewed upgrade_clicked limit_reached error_shown
  ].freeze

  class << self
    def configure
      yield config
      @client&.shutdown
      @client = nil
      config
    end

    def config
      @config ||= Configuration.new
    end

    def client
      @client ||= Client.new(config)
    end

    # Queues one usage event. Returns true when queued, false when dropped.
    def track(shop:, event:, properties: {}, event_id: nil, occurred_at: nil)
      client.track(shop: shop, event: event, properties: properties, event_id: event_id, occurred_at: occurred_at)
    end

    # Queues a shop profile: name, country, shopify_plan, email, source, utm.
    def identify(shop:, **traits)
      client.identify(shop: shop, **traits)
    end

    # Sends everything queued now, waiting at most +timeout+ seconds.
    def flush(timeout: 5)
      client.flush(timeout: timeout)
    end

    # Flushes and stops the background thread. Called automatically at exit.
    def shutdown(timeout: 5)
      @client&.shutdown(timeout: timeout)
    end

    # Checks the key against the server. Returns the server's description of
    # the app, organization and usage, or raises AppsPatrol::Error.
    def ping
      client.ping
    end

    # ---- Standard events (a convention; use track for anything else)

    # Once per shop per day: the event id is derived from the shop and the
    # date, so repeats are neither queued twice here nor stored twice there.
    def app_opened(shop:, at: Time.now.utc)
      client.app_opened(shop: shop, at: at)
    end

    def onboarding_started(shop:, **properties) = track(shop: shop, event: "onboarding_started", properties: properties)
    def onboarding_completed(shop:, **properties) = track(shop: shop, event: "onboarding_completed", properties: properties)
    def plan_viewed(shop:, **properties) = track(shop: shop, event: "plan_viewed", properties: properties)
    def upgrade_clicked(shop:, **properties) = track(shop: shop, event: "upgrade_clicked", properties: properties)

    def feature_used(shop:, feature:, **properties)
      track(shop: shop, event: "feature_used", properties: { feature: feature }.merge(properties))
    end

    def limit_reached(shop:, limit:, **properties)
      track(shop: shop, event: "limit_reached", properties: { limit: limit }.merge(properties))
    end

    def error_shown(shop:, code:, **properties)
      track(shop: shop, event: "error_shown", properties: { code: code }.merge(properties))
    end

    # Forget configuration and queued items. For tests.
    def reset!
      @client&.shutdown(timeout: 0)
      @client = nil
      @config = nil
    end

    # Used by AppsPatrol::Testing to swap in a recording client.
    attr_writer :client
  end
end

require_relative "apps_patrol/railtie" if defined?(Rails::Railtie)
