# apps_patrol

Ruby client for Apps Patrol. Sends usage events and shop profiles from your Shopify app.

- Calls return immediately; a background thread sends batches with retries
- No dependencies beyond the Ruby standard library
- Ruby 3.2 or newer
- Version 0.2.0, not published to RubyGems yet

The full reference is the `/docs/ruby` page of your Apps Patrol site. What to track: `/docs/events`.

## Install

```ruby
# Gemfile
gem "apps_patrol", git: "https://github.com/MahdiKetata99/apps-patrol-ruby.git"
# or while developing inside the monorepo:
# gem "apps_patrol", path: "packages/apps_patrol"
```

## Set up

Create an ingest key for your app under **Settings → Apps & integration**, then:

```ruby
# config/initializers/apps_patrol.rb
AppsPatrol.configure do |config|
  config.api_key  = ENV["APPS_PATROL_KEY"]
  config.base_url = "https://your-apps-patrol-host"
  config.enabled  = Rails.env.production?
end
```

Check it from a console:

```ruby
AppsPatrol.ping   # raises AppsPatrol::Error if the key or the address is wrong
```

## Use

```ruby
AppsPatrol.identify(shop: "example.myshopify.com", name: "Example Store", country: "DE", source: "app_store")

AppsPatrol.feature_used(shop: "example.myshopify.com", feature: "bulk_edit")
AppsPatrol.track(shop: "example.myshopify.com", event: "reservation_created", properties: { items: 3 })
```

In a Rails app with `shopify_app`, `app_opened` is sent once per shop per day automatically, and controllers get `track_patrol_event "feature_used", feature: "bulk_edit"`.

Standard event helpers: `app_opened`, `onboarding_started`, `onboarding_completed`, `feature_used`, `plan_viewed`, `upgrade_clicked`, `limit_reached`, `error_shown`. Any other name works with `track`.

## Options

| Option | Default | Description |
|---|---|---|
| `api_key` | `ENV["APPS_PATROL_KEY"]` | The app's ingest key |
| `base_url` | `ENV["APPS_PATROL_URL"]` or `http://localhost:3000` | Your Apps Patrol address |
| `enabled` | `true` | `false` makes every call a no-op |
| `auto_app_opened` | `true` | Rails: send `app_opened` once per shop per day |
| `logger` | `Rails.logger` or standard error | `nil` silences it |
| `on_error` | none | `->(error, context) { }` for anything that could not be sent |
| `batch_size` | `100` | Send when this many items wait |
| `flush_interval` | `2` | Seconds between sends |
| `max_queue` | `10000` | Items kept while the server is unreachable |
| `max_retries` | `5` | Attempts per request |
| `open_timeout`, `read_timeout` | `3`, `5` | Seconds |

## Testing your app

```ruby
require "apps_patrol/rspec"
RSpec.configure { |config| config.before { AppsPatrol::Testing.fake! } }

expect { do_something }.to have_tracked("feature_used").with(feature: "bulk_edit")
```

## Behaviour

- Never raises into your app and never waits for the network (except `ping`).
- Keeps items queued and retries while the server is down; drops the oldest beyond `max_queue`.
- Stops sending after a rejected key (401) until restart; pauses for an hour when the monthly quota is used.
- Restarts its queue and thread in forked processes.
- Flushes at exit. In a short script, call `AppsPatrol.flush` before it ends.

## Development

```bash
cd packages/apps_patrol
BUNDLE_GEMFILE=../../Gemfile bundle exec rspec spec
```

The specs use a scripted transport and need no network.

## License

MIT
