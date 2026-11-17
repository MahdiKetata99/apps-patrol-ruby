# frozen_string_literal: true

require_relative "lib/apps_patrol/version"

Gem::Specification.new do |spec|
  spec.name = "apps_patrol"
  spec.version = AppsPatrol::VERSION
  spec.authors = [ "MahdiKetata99" ]
  spec.summary = "Send usage events from your Shopify app to Apps Patrol"
  spec.description = "Queues usage events and shop profiles and sends them to Apps Patrol in batches from a " \
                     "background thread, with retries. No dependencies beyond the standard library."
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir["lib/**/*.rb", "README.md", "CHANGELOG.md", "LICENSE.txt"]
  spec.require_paths = [ "lib" ]
  spec.metadata = {
    "rubygems_mfa_required" => "true",
    "homepage_uri" => "https://github.com/MahdiKetata99/apps-patrol-ruby",
    "source_code_uri" => "https://github.com/MahdiKetata99/apps-patrol-ruby",
    "changelog_uri" => "https://github.com/MahdiKetata99/apps-patrol-ruby/blob/main/CHANGELOG.md"
  }
end
