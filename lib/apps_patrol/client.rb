# frozen_string_literal: true

module AppsPatrol
  # Queues events and shop profiles and sends them from a background thread.
  class Client
    MAX_BATCH = 100
    BACKOFF = [ 1, 2, 4, 8, 16 ].freeze
    QUOTA_PAUSE = 3600

    attr_reader :dropped

    def initialize(config)
      @config = config
      @queue = []
      @lock = Mutex.new
      @wake = ConditionVariable.new
      @send_lock = Mutex.new
      @opened = {}
      @dropped = 0
      @stopping = false
      @halted = nil
      @paused_until = nil
      @pid = Process.pid
      @worker = nil
      @warned_inactive = false
    end

    def track(shop:, event:, properties: {}, event_id: nil, occurred_at: nil)
      return false unless ready?
      return reject("shop is required", event: event) if shop.to_s.empty?
      return reject("event is required", shop: shop) if event.to_s.empty?

      enqueue(
        type: :event,
        payload: {
          event_id: (event_id || SecureRandom.uuid).to_s,
          shop: shop.to_s,
          name: event.to_s,
          occurred_at: (occurred_at || Time.now).utc.iso8601,
          properties: properties || {}
        }
      )
    end

    def identify(shop:, **traits)
      return false unless ready?
      return reject("shop is required") if shop.to_s.empty?

      enqueue(type: :shop, payload: { shop: shop.to_s }.merge(traits))
    end

    def app_opened(shop:, at: Time.now.utc)
      return false if shop.to_s.empty?

      day = at.utc.strftime("%Y-%m-%d")
      first = @lock.synchronize do
        next false if @opened[shop.to_s] == day

        @opened.clear if @opened.size > 50_000
        @opened[shop.to_s] = day
        true
      end
      return false unless first

      track(shop: shop, event: "app_opened", event_id: "app_opened:#{shop}:#{day}", occurred_at: at)
    end

    # Sends what is queued, in the calling thread. Returns true when the queue is empty afterwards.
    def flush(timeout: 5)
      drain(deadline: monotonic + timeout)
      @lock.synchronize { @queue.empty? }
    end

    def shutdown(timeout: 5)
      @lock.synchronize do
        @stopping = true
        @wake.broadcast
      end
      @worker&.join(timeout) if @worker && @worker != Thread.current
      flush(timeout: timeout) if timeout.positive?
      @worker = nil
      true
    end

    def ping
      response = transport.call(:get, "/v1/ping")
      return response.body if response.success?

      raise Error.new(response.error_message || "Apps Patrol answered #{response.status}", code: response.error_code, status: response.status)
    rescue Error
      raise
    rescue StandardError => e
      raise Error.new("Could not reach Apps Patrol at #{@config.base_url}: #{e.message}")
    end

    def queue_size
      @lock.synchronize { @queue.size }
    end

    private

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def transport
      @config.transport || (@default_transport ||= Transport.new(@config))
    end

    def ready?
      unless @config.active?
        if @config.enabled && !@warned_inactive
          @warned_inactive = true
          @config.logger&.warn("[AppsPatrol] No api_key configured; events are not sent")
        end
        return false
      end
      !@halted
    end

    def reject(message, context = {})
      report(ArgumentError.new(message), context)
      false
    end

    def enqueue(item)
      @lock.synchronize do
        after_fork if @pid != Process.pid
        @queue << item
        if @queue.size > @config.max_queue
          @queue.shift
          @dropped += 1
        end
        ensure_worker
        @wake.signal if @queue.size >= batch_size
      end
      true
    end

    def batch_size
      @config.batch_size.to_i.clamp(1, MAX_BATCH)
    end

    # A forked child (Puma worker, job runner) gets a copy of the parent's
    # queue and no thread. Start clean: the parent sends its own items.
    def after_fork
      @pid = Process.pid
      @queue.clear
      @worker = nil
      @stopping = false
    end

    def ensure_worker
      return if @worker&.alive? || @stopping

      register_exit_hook
      @worker = Thread.new { run }
      @worker.name = "apps_patrol" if @worker.respond_to?(:name=)
      @worker.report_on_exception = false
    end

    def register_exit_hook
      return if @exit_hook

      @exit_hook = true
      client = self
      pid = Process.pid
      at_exit { client.shutdown if Process.pid == pid }
    end

    def run
      loop do
        @lock.synchronize do
          @wake.wait(@lock, @config.flush_interval) unless @stopping || @queue.size >= batch_size
        end
        drain(deadline: monotonic + 30)
        break if @lock.synchronize { @stopping }
      end
    rescue StandardError => e
      report(e, where: "worker")
    end

    def drain(deadline:)
      @send_lock.synchronize do
        loop do
          items = @lock.synchronize { @queue.shift(batch_size) }
          break if items.empty?

          if paused?
            @dropped += items.size
            next
          end

          events, shops = items.partition { |item| item[:type] == :event }
          keep = []
          keep.concat(events) unless events.empty? || send_events(events.map { |item| item[:payload] }, deadline)
          shops.each { |item| keep << item unless send_shop(item[:payload], deadline) }
          next if keep.empty?

          # Could not be delivered before the deadline: put back for the next attempt.
          @lock.synchronize { @queue.unshift(*keep) }
          break
        end
      end
    end

    def paused?
      return true if @halted
      return false unless @paused_until
      return true if monotonic < @paused_until

      @paused_until = nil
      false
    end

    # Returns true when the request is finished (delivered or permanently refused).
    def send_events(events, deadline)
      response = request(:post, "/v1/events", { events: events }, deadline)
      return false unless response

      if response.status == 202 || (response.status == 422 && response.body.is_a?(Hash) && response.body["errors"])
        Array(response.body && response.body["errors"]).each do |error|
          event = events[error["index"].to_i] || {}
          report(Error.new("Event rejected: #{error['message']}", code: error["code"], status: response.status),
                 event: event[:name], shop: event[:shop], event_id: event[:event_id])
        end
        return true
      end

      refused(response, events: events.size)
    end

    def send_shop(payload, deadline)
      response = request(:post, "/v1/shops", payload, deadline)
      return false unless response
      return true if response.success?

      refused(response, shop: payload[:shop])
    end

    # A response that will not improve by retrying. Always "finished".
    def refused(response, context)
      case response.error_code
      when "unauthorized"
        @halted = "The ingest key was rejected"
        @config.logger&.error("[AppsPatrol] The ingest key was rejected (401). Nothing is sent until the app restarts with a valid key.")
      when "quota_exceeded"
        @paused_until = monotonic + QUOTA_PAUSE
        @config.logger&.warn("[AppsPatrol] Monthly event quota reached. Events are dropped for the next hour.")
      end
      report(Error.new(response.error_message || "Apps Patrol answered #{response.status}", code: response.error_code, status: response.status), context)
      true
    end

    # Performs the request with retries. Returns a Response, or nil when it
    # could not be completed before the deadline.
    def request(method, path, body, deadline)
      attempts = 0
      loop do
        attempts += 1
        response = begin
          transport.call(method, path, body)
        rescue StandardError => e
          e
        end

        retryable = response.is_a?(StandardError) || response.status >= 500 || response.error_code == "rate_limited"
        return response unless retryable

        wait = retry_delay(response, attempts)
        if attempts > @config.max_retries || monotonic + wait > deadline
          error = response.is_a?(StandardError) ? response : Error.new("Apps Patrol answered #{response.status}", code: response.error_code, status: response.status)
          report(error, path: path, attempts: attempts, will_retry_later: true)
          return nil
        end
        sleep(wait)
      end
    end

    def retry_delay(response, attempts)
      suggested = response.respond_to?(:retry_after) ? response.retry_after : nil
      base = suggested&.positive? ? [ suggested, 60 ].min : BACKOFF[[ attempts - 1, BACKOFF.size - 1 ].min]
      base + (rand * base * 0.25)
    end

    def report(error, context = {})
      @config.logger&.warn("[AppsPatrol] #{error.message} #{context unless context.empty?}".strip)
      @config.on_error&.call(error, context)
    rescue StandardError
      nil
    end
  end
end
