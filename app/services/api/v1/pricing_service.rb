module Api::V1
  class PricingService < BaseService
    def initialize(period:, hotel:, room:)
      @period = period
      @hotel  = hotel
      @room   = room
    end

    def run
      cached = CachedRate.fetch_fresh(period: @period, hotel: @hotel, room: @room)
      if cached
        @result = cached.rate
        return
      end

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
