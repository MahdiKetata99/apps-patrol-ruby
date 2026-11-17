# Changelog

## 0.2.0 (2026-11-17)

A rewrite. The public calls `configure`, `track` and `identify` keep their signatures.

- `track` and `identify` now queue and return; a background thread sends batches of up to 100.
- Retries with backoff for network errors, 5xx and rate limiting, honouring `Retry-After`.
- Events the server rejects and requests it refuses are logged and passed to `on_error`.
- `AppsPatrol.ping` checks the key and raises `AppsPatrol::Error` on failure.
- `AppsPatrol.flush` and `AppsPatrol.shutdown`; the queue is flushed at exit.
- Helpers for the standard events, including `app_opened` once per shop per day.
- Rails: automatic `app_opened` and `track_patrol_event` in controllers with a Shopify session.
- `apps_patrol/rspec` and `apps_patrol/testing` for the host app's tests.
- `api_key` and `base_url` default to `APPS_PATROL_KEY` and `APPS_PATROL_URL`.
- Requires the Apps Patrol API error format introduced on the same date.

## 0.1.0

Initial sketch: one blocking request per call, errors swallowed.
