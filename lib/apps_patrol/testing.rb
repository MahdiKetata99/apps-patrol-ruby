# frozen_string_literal: true

require_relative "../apps_patrol"

module AppsPatrol
  # Records calls instead of sending them, for the host app's test suite.
  #
  #   # spec/rails_helper.rb
  #   require "apps_patrol/rspec"   # or "apps_patrol/testing" without the matcher
  #   RSpec.configure { |c| c.before { AppsPatrol::Testing.fake! } }
  #
  #   expect(AppsPatrol::Testing.events).to include(a_hash_including(name: "feature_used"))
  #   expect { post "/things" }.to have_tracked("feature_used").with(feature: "bulk_edit")
  module Testing
    class FakeClient
      attr_reader :events, :shops

      def initialize
        @events = []
        @shops = []
        @opened = {}
      end

      def track(shop:, event:, properties: {}, event_id: nil, occurred_at: nil)
        @events << { shop: shop.to_s, name: event.to_s, properties: (properties || {}).transform_keys(&:to_sym), event_id: event_id, occurred_at: occurred_at }
        true
      end

      def identify(shop:, **traits)
        @shops << { shop: shop.to_s }.merge(traits)
        true
      end

      def app_opened(shop:, at: Time.now.utc)
        day = at.utc.strftime("%Y-%m-%d")
        return false if @opened[shop.to_s] == day

        @opened[shop.to_s] = day
        track(shop: shop, event: "app_opened", event_id: "app_opened:#{shop}:#{day}", occurred_at: at)
      end

      def flush(**) = true
      def shutdown(**) = true
      def ping = { "ok" => true, "test" => true }
      def queue_size = 0
    end

    class << self
      # Replace the client with a recorder and clear anything recorded before.
      def fake!
        AppsPatrol.client = FakeClient.new
      end

      def events = recorder.events
      def shops = recorder.shops

      def events_named(name)
        events.select { |event| event[:name] == name.to_s }
      end

      private

      def recorder
        client = AppsPatrol.client
        client.is_a?(FakeClient) ? client : fake!
      end
    end
  end
end
