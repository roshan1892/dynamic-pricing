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
      if response.success?
        parsed = JSON.parse(response.body)
        rate = parsed['rates']
                 .detect { |r| r['period'] == @period && r['hotel'] == @hotel && r['room'] == @room }
                 &.dig('rate')

        if rate
          CachedRate.store(period: @period, hotel: @hotel, room: @room, rate: rate)
          @result = rate
        else
          errors << { code: 'RATE_NOT_FOUND', message: 'No rate was returned for the requested combination.' }
        end
      else
        errors << { code: 'UPSTREAM_ERROR', message: 'The upstream pricing API returned an unexpected error.' }
      end
    end
  end
end
