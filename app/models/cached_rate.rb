class CachedRate < ApplicationRecord
  extend StructuredLogging

  VALID_DURATION = 5.minutes

  def self.fetch_fresh(period:, hotel:, room:)
    start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    cached = find_by(period: period, hotel: hotel, room: room)
               &.then { |c| c if c.fetched_at > VALID_DURATION.ago }
    log_event(:info, event: 'cache_read', period: period, hotel: hotel, room: room,
              hit: !cached.nil?, duration_ms: elapsed_ms(start_time))
    cached
  end

  def self.store(period:, hotel:, room:, rate:)
    start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    upsert(
      { period: period, hotel: hotel, room: room, rate: rate, fetched_at: Time.current },
      unique_by: [:period, :hotel, :room]
    )
    log_event(:info, event: 'cache_store', period: period, hotel: hotel, room: room,
              duration_ms: elapsed_ms(start_time))
  end
end
