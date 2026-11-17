# frozen_string_literal: true

require "net/http"
require "uri"

module AppsPatrol
  # What a transport returns: HTTP status, parsed JSON body (or nil) and headers.
  Response = Struct.new(:status, :body, :headers) do
    def success? = status.between?(200, 299)
    def error_code = body.is_a?(Hash) && body["error"].is_a?(Hash) ? body["error"]["code"] : nil
    def error_message = body.is_a?(Hash) && body["error"].is_a?(Hash) ? body["error"]["message"] : nil
    def retry_after = headers["retry-after"]&.to_f
  end

  # Default transport: the standard library's Net::HTTP with short timeouts.
  class Transport
    def initialize(config)
      @config = config
    end

    # method is :get or :post; body is a Hash or nil. Raises on network failure.
    def call(method, path, body = nil, headers = {})
      uri = URI.join(@config.base_url.to_s.chomp("/") + "/", path.sub(%r{\A/}, ""))
      request = (method == :get ? Net::HTTP::Get : Net::HTTP::Post).new(uri)
      request["Authorization"] = "Bearer #{@config.api_key}"
      request["User-Agent"] = "apps_patrol-ruby/#{AppsPatrol::VERSION}"
      headers.each { |name, value| request[name] = value }
      if body
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(body)
      end

      response = Net::HTTP.start(
        uri.host, uri.port,
        use_ssl: uri.scheme == "https", open_timeout: @config.open_timeout, read_timeout: @config.read_timeout
      ) { |http| http.request(request) }

      Response.new(response.code.to_i, parse(response.body), response.each_header.to_h)
    end

    private

    def parse(text)
      JSON.parse(text) if text && !text.empty?
    rescue JSON::ParserError
      nil
    end
  end
end
