# frozen_string_literal: true

require_relative "../lib/apps_patrol"
require_relative "../lib/apps_patrol/rspec"

# A transport that records requests and replays scripted responses.
class ScriptedTransport
  attr_reader :requests

  def initialize(*responses)
    @responses = responses
    @requests = []
    @lock = Mutex.new
  end

  def call(method, path, body = nil, _headers = {})
    @lock.synchronize do
      @requests << { method: method, path: path, body: body }
      response = @responses.size > 1 ? @responses.shift : @responses.first
      raise response if response.is_a?(Exception)

      response
    end
  end

  def events = requests.select { |r| r[:path] == "/v1/events" }.flat_map { |r| r[:body][:events] }
end

def ok(body = { "accepted" => 1, "duplicates" => 0, "errors" => [] }, status: 202)
  AppsPatrol::Response.new(status, body, {})
end

def api_error(status, code, headers = {})
  AppsPatrol::Response.new(status, { "error" => { "code" => code, "message" => "#{code} happened" } }, headers)
end

RSpec.describe AppsPatrol do
  let(:errors) { [] }
  let(:transport) { ScriptedTransport.new(ok) }

  def configure(transport: self.transport, **options)
    AppsPatrol.configure do |config|
      config.api_key = "ap_test"
      config.transport = transport
      config.logger = nil
      config.flush_interval = 3600 # the specs flush explicitly
      config.on_error = ->(error, context) { errors << [ error, context ] }
      options.each { |key, value| config.public_send("#{key}=", value) }
    end
  end

  before { AppsPatrol.reset! }
  after { AppsPatrol.reset! }

  describe "tracking" do
    it "queues without sending, then sends one batch on flush" do
      configure
      expect(AppsPatrol.track(shop: "a.myshopify.com", event: "feature_used", properties: { feature: "bulk_edit" })).to be(true)
      AppsPatrol.track(shop: "b.myshopify.com", event: "app_opened")
      expect(transport.requests).to be_empty

      expect(AppsPatrol.flush).to be(true)
      expect(transport.requests.size).to eq(1)
      first, second = transport.events
      expect(first).to include(shop: "a.myshopify.com", name: "feature_used", properties: { feature: "bulk_edit" })
      expect(first[:event_id]).to match(/\A\h{8}-/)
      expect(Time.iso8601(first[:occurred_at])).to be_within(5).of(Time.now)
      expect(second).to include(name: "app_opened")
    end

    it "splits more than 100 events into several requests" do
      configure
      250.times { |i| AppsPatrol.track(shop: "a.myshopify.com", event: "e#{i}") }
      AppsPatrol.flush
      expect(transport.requests.map { |r| r[:body][:events].size }).to eq([ 100, 100, 50 ])
    end

    it "sends in the background when a batch is full" do
      configure(batch_size: 5)
      5.times { AppsPatrol.track(shop: "a.myshopify.com", event: "x") }
      deadline = Time.now + 3
      sleep 0.02 until transport.requests.any? || Time.now > deadline
      expect(transport.events.size).to eq(5)
    end

    it "sends shop profiles to the shops endpoint" do
      configure(transport: ScriptedTransport.new(AppsPatrol::Response.new(202, { "shop" => "a.myshopify.com" }, {})))
      AppsPatrol.identify(shop: "a.myshopify.com", name: "A", country: "DE", utm: { utm_source: "ads" })
      AppsPatrol.flush
      request = AppsPatrol.config.transport.requests.first
      expect(request).to include(path: "/v1/shops", body: { shop: "a.myshopify.com", name: "A", country: "DE", utm: { utm_source: "ads" } })
    end

    it "drops calls without a shop or a name and reports them" do
      configure
      expect(AppsPatrol.track(shop: "", event: "x")).to be(false)
      expect(AppsPatrol.track(shop: "a.myshopify.com", event: nil)).to be(false)
      expect(errors.map { |error, _| error.message }).to eq([ "shop is required", "event is required" ])
      expect(AppsPatrol.client.queue_size).to eq(0)
    end

    it "does nothing when disabled or without a key" do
      configure(enabled: false)
      expect(AppsPatrol.track(shop: "a.myshopify.com", event: "x")).to be(false)
      configure(api_key: nil)
      expect(AppsPatrol.track(shop: "a.myshopify.com", event: "x")).to be(false)
      AppsPatrol.flush
      expect(transport.requests).to be_empty
    end

    it "keeps only the newest items when the queue overflows" do
      configure(max_queue: 3, batch_size: 100)
      5.times { |i| AppsPatrol.track(shop: "a.myshopify.com", event: "e#{i}") }
      expect(AppsPatrol.client.dropped).to eq(2)
      AppsPatrol.flush
      expect(transport.events.map { |e| e[:name] }).to eq(%w[e2 e3 e4])
    end
  end

  describe "forked processes" do
    it "starts with an empty queue instead of resending the parent's items" do
      configure
      AppsPatrol.track(shop: "a.myshopify.com", event: "queued_in_parent")
      allow(Process).to receive(:pid).and_return(Process.pid + 1)

      AppsPatrol.track(shop: "a.myshopify.com", event: "queued_in_child")
      AppsPatrol.flush
      expect(transport.events.map { |e| e[:name] }).to eq([ "queued_in_child" ])
    end
  end

  describe "standard events" do
    it "sends app_opened once per shop per day with a stable id" do
      configure
      day = Time.utc(2026, 11, 17, 9)
      expect(AppsPatrol.app_opened(shop: "a.myshopify.com", at: day)).to be(true)
      expect(AppsPatrol.app_opened(shop: "a.myshopify.com", at: day + 3600)).to be(false)
      AppsPatrol.app_opened(shop: "b.myshopify.com", at: day)
      AppsPatrol.app_opened(shop: "a.myshopify.com", at: day + 86_400)
      AppsPatrol.flush

      expect(transport.events.map { |e| e[:event_id] }).to eq(
        %w[app_opened:a.myshopify.com:2026-11-17 app_opened:b.myshopify.com:2026-11-17 app_opened:a.myshopify.com:2026-11-18]
      )
    end

    it "has a helper for each standard name" do
      configure
      AppsPatrol.onboarding_started(shop: "a.myshopify.com")
      AppsPatrol.onboarding_completed(shop: "a.myshopify.com", steps: 3)
      AppsPatrol.feature_used(shop: "a.myshopify.com", feature: "bulk_edit", items: 4)
      AppsPatrol.plan_viewed(shop: "a.myshopify.com")
      AppsPatrol.upgrade_clicked(shop: "a.myshopify.com", plan: "pro")
      AppsPatrol.limit_reached(shop: "a.myshopify.com", limit: "products")
      AppsPatrol.error_shown(shop: "a.myshopify.com", code: "sync_failed")
      AppsPatrol.flush

      expect(transport.events.map { |e| e[:name] }).to eq(AppsPatrol::STANDARD_EVENTS - [ "app_opened" ])
      expect(transport.events[2][:properties]).to eq(feature: "bulk_edit", items: 4)
      expect(transport.events[5][:properties]).to eq(limit: "products")
    end
  end

  describe "delivery" do
    before { allow_any_instance_of(AppsPatrol::Client).to receive(:sleep) }

    it "retries network errors and server errors, then delivers" do
      configure(transport: ScriptedTransport.new(Errno::ECONNREFUSED.new, api_error(503, "server_error"), ok))
      AppsPatrol.track(shop: "a.myshopify.com", event: "x")
      expect(AppsPatrol.flush(timeout: 120)).to be(true)
      expect(AppsPatrol.config.transport.requests.size).to eq(3)
      expect(errors).to be_empty
    end

    it "waits for Retry-After when rate limited" do
      configure(transport: ScriptedTransport.new(api_error(429, "rate_limited", "retry-after" => "7"), ok))
      expect_any_instance_of(AppsPatrol::Client).to receive(:sleep).with(a_value_between(7, 9))
      AppsPatrol.track(shop: "a.myshopify.com", event: "x")
      expect(AppsPatrol.flush(timeout: 120)).to be(true)
    end

    it "keeps events queued when the server stays down" do
      configure(transport: ScriptedTransport.new(Errno::ECONNREFUSED.new), max_retries: 2)
      AppsPatrol.track(shop: "a.myshopify.com", event: "x")
      expect(AppsPatrol.flush(timeout: 120)).to be(false)
      expect(AppsPatrol.client.queue_size).to eq(1)
      expect(errors.last[1]).to include(will_retry_later: true)
    end

    it "does not retry a request the server refuses" do
      configure(transport: ScriptedTransport.new(api_error(422, "batch_too_large")))
      AppsPatrol.track(shop: "a.myshopify.com", event: "x")
      expect(AppsPatrol.flush).to be(true)
      expect(AppsPatrol.config.transport.requests.size).to eq(1)
      expect(errors.first[0]).to have_attributes(code: "batch_too_large", status: 422)
    end

    it "reports events the server rejected and treats the batch as delivered" do
      body = { "accepted" => 1, "duplicates" => 0, "errors" => [ { "index" => 1, "code" => "invalid_name", "message" => "name may use lowercase letters" } ] }
      configure(transport: ScriptedTransport.new(ok(body)))
      AppsPatrol.track(shop: "a.myshopify.com", event: "good")
      AppsPatrol.track(shop: "a.myshopify.com", event: "Bad Name")
      expect(AppsPatrol.flush).to be(true)
      error, context = errors.first
      expect(error.code).to eq("invalid_name")
      expect(context).to include(event: "Bad Name", shop: "a.myshopify.com")
    end

    it "stops sending after the key is rejected" do
      configure(transport: ScriptedTransport.new(api_error(401, "unauthorized")))
      AppsPatrol.track(shop: "a.myshopify.com", event: "x")
      AppsPatrol.flush
      expect(AppsPatrol.track(shop: "a.myshopify.com", event: "y")).to be(false)
      expect(AppsPatrol.config.transport.requests.size).to eq(1)
    end

    it "pauses for an hour when the monthly quota is used" do
      configure(transport: ScriptedTransport.new(api_error(429, "quota_exceeded")))
      AppsPatrol.track(shop: "a.myshopify.com", event: "x")
      AppsPatrol.flush
      AppsPatrol.track(shop: "a.myshopify.com", event: "y")
      AppsPatrol.flush
      expect(AppsPatrol.config.transport.requests.size).to eq(1)
      expect(AppsPatrol.client.dropped).to eq(1)
    end

    it "never raises into the caller" do
      configure(transport: ScriptedTransport.new(RuntimeError.new("boom")), max_retries: 0, on_error: ->(*) { raise "handler failed" })
      expect { AppsPatrol.track(shop: "a.myshopify.com", event: "x") }.not_to raise_error
      expect { AppsPatrol.flush }.not_to raise_error
    end
  end

  describe "ping" do
    it "returns the server's description of the key" do
      configure(transport: ScriptedTransport.new(AppsPatrol::Response.new(200, { "ok" => true, "app" => { "name" => "Cart Holder" } }, {})))
      expect(AppsPatrol.ping.dig("app", "name")).to eq("Cart Holder")
    end

    it "raises a clear error for a bad key or an unreachable server" do
      configure(transport: ScriptedTransport.new(api_error(401, "unauthorized")))
      expect { AppsPatrol.ping }.to raise_error(AppsPatrol::Error) { |e| expect(e.code).to eq("unauthorized") }

      configure(transport: ScriptedTransport.new(Errno::ECONNREFUSED.new))
      expect { AppsPatrol.ping }.to raise_error(AppsPatrol::Error, /Could not reach Apps Patrol/)
    end
  end

  describe "testing helpers" do
    before { AppsPatrol::Testing.fake! }

    it "records events instead of sending them" do
      AppsPatrol.feature_used(shop: "a.myshopify.com", feature: "bulk_edit")
      AppsPatrol.identify(shop: "a.myshopify.com", country: "DE")
      expect(AppsPatrol::Testing.events_named("feature_used").first[:properties]).to eq(feature: "bulk_edit")
      expect(AppsPatrol::Testing.shops).to eq([ { shop: "a.myshopify.com", country: "DE" } ])
    end

    it "offers a have_tracked matcher" do
      expect { AppsPatrol.feature_used(shop: "a.myshopify.com", feature: "bulk_edit") }
        .to have_tracked("feature_used").with(feature: "bulk_edit").for_shop("a.myshopify.com")
      expect { AppsPatrol.plan_viewed(shop: "a.myshopify.com") }.not_to have_tracked("feature_used")
    end
  end
end
