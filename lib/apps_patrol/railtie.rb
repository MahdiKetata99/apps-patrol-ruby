# frozen_string_literal: true

module AppsPatrol
  # Controller helpers, included into ActionController::Base by the railtie.
  module ControllerHelpers
    def self.included(base)
      base.after_action :patrol_track_app_opened if base.respond_to?(:after_action)
    end

    private

    # Tracks an event for the shop of the current Shopify session.
    #
    #   track_patrol_event "feature_used", feature: "bulk_edit"
    def track_patrol_event(name, properties = {})
      shop = patrol_shop_domain
      AppsPatrol.track(shop: shop, event: name, properties: properties) if shop
    end

    # The shop behind this request, when the controller is one of shopify_app's
    # authenticated controllers. Override to supply the shop another way.
    def patrol_shop_domain
      return nil unless respond_to?(:current_shopify_domain, true)

      domain = current_shopify_domain
      domain.to_s.empty? ? nil : domain.to_s
    rescue StandardError
      nil
    end

    def patrol_track_app_opened
      return unless AppsPatrol.config.auto_app_opened && AppsPatrol.config.active?
      return unless request.get? && response.successful? && request.format.html?

      shop = patrol_shop_domain
      AppsPatrol.app_opened(shop: shop) if shop
    rescue StandardError
      nil
    end
  end

  class Railtie < ::Rails::Railtie
    initializer "apps_patrol.logger" do
      AppsPatrol.config.logger = ::Rails.logger
    end

    initializer "apps_patrol.controller_helpers" do
      ActiveSupport.on_load(:action_controller_base) { include AppsPatrol::ControllerHelpers }
    end
  end
end
