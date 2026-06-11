class CachedRate < ApplicationRecord
  VALID_DURATION = 5.minutes

  def self.fetch_fresh(period:, hotel:, room:)
    find_by(period: period, hotel: hotel, room: room)
      &.then { |cached| cached if cached.fetched_at > VALID_DURATION.ago }
  end

  def self.store(period:, hotel:, room:, rate:)
    upsert(
      { period: period, hotel: hotel, room: room, rate: rate, fetched_at: Time.current },
      unique_by: [:period, :hotel, :room]
    )
  end
end
