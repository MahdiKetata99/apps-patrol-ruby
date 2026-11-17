# frozen_string_literal: true

require "rspec/expectations"
require_relative "testing"

# expect { ... }.to have_tracked("feature_used").with(feature: "bulk_edit").for_shop("store.myshopify.com")
RSpec::Matchers.define :have_tracked do |name|
  supports_block_expectations

  chain(:with) { |properties| @properties = properties }
  chain(:for_shop) { |shop| @shop = shop }

  match do |block|
    before = AppsPatrol::Testing.events.size
    block.call
    @seen = AppsPatrol::Testing.events.drop(before)
    @seen.any? do |event|
      event[:name] == name.to_s &&
        (@shop.nil? || event[:shop] == @shop.to_s) &&
        (@properties.nil? || @properties.all? { |key, value| values_match?(value, event[:properties][key.to_sym]) })
    end
  end

  failure_message do
    seen = @seen.map { |event| "#{event[:name]} #{event[:properties]}" }.join(", ")
    "expected the block to track #{name.inspect}#{" with #{@properties}" if @properties}, but it tracked: #{seen.empty? ? 'nothing' : seen}"
  end
end
