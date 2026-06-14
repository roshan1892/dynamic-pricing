require "test_helper"

class CachedRateTest < ActiveSupport::TestCase
  setup do
    CachedRate.delete_all
  end

  # No row in DB — returns nil
  test "fetch_fresh returns nil when no entry exists" do
    result = CachedRate.fetch_fresh(period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom")
    assert_nil result
  end

  # Row exists but fetched_at is older than 5 minutes — returns nil
  test "fetch_fresh returns nil when entry is stale" do
    CachedRate.create!(
      period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom",
      rate: "15000", fetched_at: 6.minutes.ago
    )

    result = CachedRate.fetch_fresh(period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom")
    assert_nil result
  end

  # Row exists and fetched_at is within 5 minutes — returns the cached record
  test "fetch_fresh returns entry when fresh" do
    CachedRate.create!(
      period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom",
      rate: "15000", fetched_at: 1.minute.ago
    )

    result = CachedRate.fetch_fresh(period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom")
    assert_not_nil result
    assert_equal "15000", result.rate
  end

  # Boundary condition — exactly 5 minutes old is stale, not fresh
  test "fetch_fresh returns nil at exactly 5 minutes old" do
    CachedRate.create!(
      period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom",
      rate: "15000", fetched_at: 5.minutes.ago
    )

    result = CachedRate.fetch_fresh(period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom")
    assert_nil result
  end

  # No existing row — upsert creates a new entry with fetched_at set to now
  test "store creates a new cache entry when none exists" do
    CachedRate.store(period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom", rate: "15000")

    cached = CachedRate.find_by(period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom")
    assert_not_nil cached
    assert_equal "15000", cached.rate
    assert cached.fetched_at > 1.minute.ago
  end

  # Existing row — upsert updates rate and fetched_at without creating a duplicate
  test "store updates existing entry without creating duplicate" do
    CachedRate.create!(
      period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom",
      rate: "15000", fetched_at: 6.minutes.ago
    )

    CachedRate.store(period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom", rate: "20000")

    assert_equal 1, CachedRate.where(period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom").count
    cached = CachedRate.find_by(period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom")
    assert_equal "20000", cached.rate
    assert cached.fetched_at > 1.minute.ago
  end
end
