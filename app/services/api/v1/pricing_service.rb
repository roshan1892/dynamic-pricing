module Api::V1
  class PricingService < BaseService
    # One Mutex per unique cache key — only threads competing for the same
    # combination block each other. Unrelated combinations proceed in parallel.
    LOCKS = Hash.new { |h, k| h[k] = Mutex.new }

    def initialize(period:, hotel:, room:)
      @period = period
      @hotel  = hotel
      @room   = room
    end

    def run
      # First check outside the lock — cache hit requires no locking at all
      return if load_from_cache

      LOCKS[cache_key].synchronize do
        # Second check inside the lock — another thread may have refreshed
        # the cache while we were waiting to acquire the Mutex
        return if load_from_cache

        fetch_rate_and_cache
      end
    end

    private

    def load_from_cache
      cached = CachedRate.fetch_fresh(period: @period, hotel: @hotel, room: @room)
      @result = cached.rate if cached
    end

    def cache_key
      "#{@period}.#{@hotel}.#{@room}"
    end

    def fetch_rate_and_cache
      response = RateApiClient.get_rate(period: @period, hotel: @hotel, room: @room)

      # API docs only document happy path — error format is unknown and unstable.
      # Log raw response for debugging, return our own structured error to the client.
      if response.code == 429
        Rails.logger.warn({ event: 'upstream_rate_limit', body: response.body.to_s }.to_json)
        errors << { code: 'RATE_LIMIT_EXCEEDED', message: 'The upstream pricing API daily quota has been exhausted. Please try again later.' }
        return
      end

      unless response.success?
        Rails.logger.error({ event: 'upstream_error', http_code: response.code, body: response.body.to_s }.to_json)
        errors << { code: 'UPSTREAM_ERROR', message: "The upstream pricing API returned an unexpected error (HTTP #{response.code})." }
        return
      end

      rate = parse_rate(response.body)
      return unless errors.empty?

      CachedRate.store(period: @period, hotel: @hotel, room: @room, rate: rate)
      @result = rate
    rescue RateApiClient::TimeoutError
      errors << { code: 'UPSTREAM_TIMEOUT', message: 'The upstream pricing API did not respond in time. Please try again.' }
    rescue RateApiClient::ConnectionError
      errors << { code: 'UPSTREAM_TIMEOUT', message: 'The upstream pricing API is unreachable. Please try again.' }
    rescue JSON::ParserError
      errors << { code: 'UPSTREAM_ERROR', message: 'The upstream pricing API returned an unreadable response.' }
    end

    def parse_rate(body)
      # Raises JSON::ParserError if the upstream response is not valid JSON
      # e.g. HTML error pages, plain text responses, or malformed payloads
      parsed = JSON.parse(body)
      rate = parsed['rates']
               .detect { |r| r['period'] == @period && r['hotel'] == @hotel && r['room'] == @room }
               &.dig('rate')

      unless rate
        errors << { code: 'RATE_NOT_FOUND', message: 'No rate was returned for the requested combination.' }
      end

      rate
    end
  end
end
