require "test_helper"

class Api::V1::PricingControllerTest < ActionDispatch::IntegrationTest
  setup do
    CachedRate.delete_all
  end

  # --- Existing tests (1-7) ---

  # Full happy path — valid params, upstream returns a rate
  test "should get pricing with all parameters" do
    mock_body = {
      'rates' => [
        { 'period' => 'Summer', 'hotel' => 'FloatingPointResort', 'room' => 'SingletonRoom', 'rate' => '15000' }
      ]
    }.to_json

    mock_response = OpenStruct.new(success?: true, body: mock_body)

    RateApiClient.stub(:get_rate, mock_response) do
      get api_v1_pricing_url, params: {
        period: "Summer",
        hotel: "FloatingPointResort",
        room: "SingletonRoom"
      }

      assert_response :success
      assert_equal "application/json", @response.media_type

      json_response = JSON.parse(@response.body)
      assert_equal "15000", json_response["rate"]
    end
  end

  # Upstream returns 500 — service returns structured UPSTREAM_ERROR
  test "should return error when rate API fails" do
    mock_response = OpenStruct.new(success?: false, code: 500, body: '{}')

    RateApiClient.stub(:get_rate, mock_response) do
      get api_v1_pricing_url, params: {
        period: "Summer",
        hotel: "FloatingPointResort",
        room: "SingletonRoom"
      }

      assert_response :service_unavailable
      assert_equal "application/json", @response.media_type

      json_response = JSON.parse(@response.body)
      assert_equal "UPSTREAM_ERROR", json_response["code"]
      assert_includes json_response["message"], "unexpected error"
    end
  end

  # All three required params missing
  test "should return error without any parameters" do
    get api_v1_pricing_url

    assert_response :bad_request
    assert_equal "application/json", @response.media_type

    json_response = JSON.parse(@response.body)
    assert_equal "INVALID_PARAMETERS", json_response["code"]
    assert_includes json_response["message"], "Missing required parameters"
  end

  # All three params present but empty strings
  test "should handle empty parameters" do
    get api_v1_pricing_url, params: {
      period: "",
      hotel: "",
      room: ""
    }

    assert_response :bad_request
    assert_equal "application/json", @response.media_type

    json_response = JSON.parse(@response.body)
    assert_equal "INVALID_PARAMETERS", json_response["code"]
    assert_includes json_response["message"], "Missing required parameters"
  end

  # period value not in allowed list
  test "should reject invalid period" do
    get api_v1_pricing_url, params: {
      period: "summer-2024",
      hotel: "FloatingPointResort",
      room: "SingletonRoom"
    }

    assert_response :bad_request
    assert_equal "application/json", @response.media_type

    json_response = JSON.parse(@response.body)
    assert_equal "INVALID_PARAMETERS", json_response["code"]
    assert_includes json_response["message"], "Invalid period"
  end

  # hotel value not in allowed list
  test "should reject invalid hotel" do
    get api_v1_pricing_url, params: {
      period: "Summer",
      hotel: "InvalidHotel",
      room: "SingletonRoom"
    }

    assert_response :bad_request
    assert_equal "application/json", @response.media_type

    json_response = JSON.parse(@response.body)
    assert_equal "INVALID_PARAMETERS", json_response["code"]
    assert_includes json_response["message"], "Invalid hotel"
  end

  # room value not in allowed list
  test "should reject invalid room" do
    get api_v1_pricing_url, params: {
      period: "Summer",
      hotel: "FloatingPointResort",
      room: "InvalidRoom"
    }

    assert_response :bad_request
    assert_equal "application/json", @response.media_type

    json_response = JSON.parse(@response.body)
    assert_equal "INVALID_PARAMETERS", json_response["code"]
    assert_includes json_response["message"], "Invalid room"
  end

  # --- New tests (8+) ---

  # Fresh cache entry exists — upstream API must not be called
  test "should serve rate from cache without calling API" do
    CachedRate.create!(
      period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom",
      rate: "15000", fetched_at: 1.minute.ago
    )

    api_called = false
    RateApiClient.stub(:get_rate, -> (*) { api_called = true }) do
      get api_v1_pricing_url, params: {
        period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom"
      }
    end

    assert_response :success
    assert_equal false, api_called
    assert_equal "15000", JSON.parse(@response.body)["rate"]
  end

  # No cache entry — upstream called, result stored for future requests
  test "should call API on cache miss and store result in cache" do
    mock_body = { 'rates' => [{ 'period' => 'Summer', 'hotel' => 'FloatingPointResort', 'room' => 'SingletonRoom', 'rate' => '15000' }] }.to_json
    mock_response = OpenStruct.new(success?: true, code: 200, body: mock_body)

    api_called = false
    RateApiClient.stub(:get_rate, ->(*) { api_called = true; mock_response }) do
      get api_v1_pricing_url, params: {
        period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom"
      }
    end

    assert_equal true, api_called
    assert_response :success
    assert_equal "15000", JSON.parse(@response.body)["rate"]
    cached = CachedRate.find_by(period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom")
    assert_not_nil cached
    assert_equal "15000", cached.rate
  end

  # Stale cache (> 5 min) — upstream called, cached rate updated with fresh value
  test "should call API again when cache is stale and update cached rate" do
    CachedRate.create!(
      period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom",
      rate: "10000", fetched_at: 6.minutes.ago
    )

    mock_body = { 'rates' => [{ 'period' => 'Summer', 'hotel' => 'FloatingPointResort', 'room' => 'SingletonRoom', 'rate' => '20000' }] }.to_json
    mock_response = OpenStruct.new(success?: true, code: 200, body: mock_body)

    api_called = false
    RateApiClient.stub(:get_rate, ->(*) { api_called = true; mock_response }) do
      get api_v1_pricing_url, params: {
        period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom"
      }
    end

    assert_equal true, api_called
    assert_response :success
    assert_equal "20000", JSON.parse(@response.body)["rate"]
    cached = CachedRate.find_by(period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom")
    assert_equal "20000", cached.rate
  end

  # Fresh cache (4 min old) — upstream must not be called, 1 min within TTL
  test "should not call API when cache is fresh" do
    CachedRate.create!(
      period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom",
      rate: "15000", fetched_at: 4.minutes.ago
    )

    api_called = false
    RateApiClient.stub(:get_rate, ->(*) { api_called = true }) do
      get api_v1_pricing_url, params: {
        period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom"
      }
    end

    assert_equal false, api_called
    assert_response :success
    assert_equal "15000", JSON.parse(@response.body)["rate"]
  end

  # TTL boundary — exactly 5 minutes old is treated as stale, not fresh
  test "should treat cache as stale when exactly 5 minutes old" do
    CachedRate.create!(
      period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom",
      rate: "10000", fetched_at: 5.minutes.ago
    )

    mock_body = { 'rates' => [{ 'period' => 'Summer', 'hotel' => 'FloatingPointResort', 'room' => 'SingletonRoom', 'rate' => '20000' }] }.to_json
    mock_response = OpenStruct.new(success?: true, code: 200, body: mock_body)

    api_called = false
    RateApiClient.stub(:get_rate, ->(*) { api_called = true; mock_response }) do
      get api_v1_pricing_url, params: {
        period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom"
      }
    end

    assert_equal true, api_called
    assert_response :success
    assert_equal "20000", JSON.parse(@response.body)["rate"]
  end

  # Upstream returns 429 — specific RATE_LIMIT_EXCEEDED code, not generic error
  test "should return RATE_LIMIT_EXCEEDED when API returns 429" do
    mock_response = OpenStruct.new(success?: false, code: 429, body: '{}')

    RateApiClient.stub(:get_rate, mock_response) do
      get api_v1_pricing_url, params: {
        period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom"
      }
    end

    assert_response :service_unavailable
    assert_equal "application/json", @response.media_type
    json_response = JSON.parse(@response.body)
    assert_equal "RATE_LIMIT_EXCEEDED", json_response["code"]
    assert_includes json_response["message"], "quota"
  end

  # Connection established but no response within timeout window
  test "should return UPSTREAM_TIMEOUT when API times out" do
    RateApiClient.stub(:get_rate, ->(*) { raise RateApiClient::TimeoutError }) do
      get api_v1_pricing_url, params: {
        period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom"
      }
    end

    assert_response :service_unavailable
    assert_equal "application/json", @response.media_type
    json_response = JSON.parse(@response.body)
    assert_equal "UPSTREAM_TIMEOUT", json_response["code"]
    assert_includes json_response["message"], "did not respond in time"
  end

  # Cannot establish connection to upstream server
  test "should return UPSTREAM_TIMEOUT when API is unreachable" do
    RateApiClient.stub(:get_rate, ->(*) { raise RateApiClient::ConnectionError }) do
      get api_v1_pricing_url, params: {
        period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom"
      }
    end

    assert_response :service_unavailable
    assert_equal "application/json", @response.media_type
    json_response = JSON.parse(@response.body)
    assert_equal "UPSTREAM_TIMEOUT", json_response["code"]
    assert_includes json_response["message"], "unreachable"
  end

  # Upstream returns 200 but body is not valid JSON (e.g. HTML error page)
  test "should return UPSTREAM_ERROR when API returns malformed JSON" do
    mock_response = OpenStruct.new(success?: true, code: 200, body: 'not valid json')

    RateApiClient.stub(:get_rate, mock_response) do
      get api_v1_pricing_url, params: {
        period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom"
      }
    end

    assert_response :service_unavailable
    assert_equal "application/json", @response.media_type
    json_response = JSON.parse(@response.body)
    assert_equal "UPSTREAM_ERROR", json_response["code"]
    assert_includes json_response["message"], "unreadable"
  end

  # Upstream returns 200 with empty rates array — no matching combination
  test "should return RATE_NOT_FOUND when rate is missing in successful response" do
    mock_body = { 'rates' => [] }.to_json
    mock_response = OpenStruct.new(success?: true, code: 200, body: mock_body)

    RateApiClient.stub(:get_rate, mock_response) do
      get api_v1_pricing_url, params: {
        period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom"
      }
    end

    assert_response :service_unavailable
    assert_equal "application/json", @response.media_type
    json_response = JSON.parse(@response.body)
    assert_equal "RATE_NOT_FOUND", json_response["code"]
    assert_includes json_response["message"], "No rate was returned"
  end

  # Upstream returns matching object but 'rate' field is absent — &.dig returns nil
  test "should return RATE_NOT_FOUND when rate field is missing in response object" do
    mock_body = { 'rates' => [{ 'period' => 'Summer', 'hotel' => 'FloatingPointResort', 'room' => 'SingletonRoom' }] }.to_json
    mock_response = OpenStruct.new(success?: true, code: 200, body: mock_body)

    RateApiClient.stub(:get_rate, mock_response) do
      get api_v1_pricing_url, params: {
        period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom"
      }
    end

    assert_response :service_unavailable
    assert_equal "application/json", @response.media_type
    json_response = JSON.parse(@response.body)
    assert_equal "RATE_NOT_FOUND", json_response["code"]
    assert_includes json_response["message"], "No rate was returned"
  end

  # Unhandled exception in service — controller safety net returns JSON instead of HTML
  test "should return INTERNAL_ERROR when unexpected exception is raised" do
    Api::V1::PricingService.stub(:new, ->(*) { raise StandardError, "unexpected" }) do
      get api_v1_pricing_url, params: {
        period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom"
      }
    end

    assert_response :internal_server_error
    assert_equal "application/json", @response.media_type
    json_response = JSON.parse(@response.body)
    assert_equal "INTERNAL_ERROR", json_response["code"]
    assert_includes json_response["message"], "unexpected error occurred"
  end

  # Upstream returns 3xx — HTTParty normally follows redirects but handles unexpected ones
  test "should return UPSTREAM_ERROR when API returns 3xx redirect" do
    mock_response = OpenStruct.new(success?: false, code: 301, body: '{}')

    RateApiClient.stub(:get_rate, mock_response) do
      get api_v1_pricing_url, params: {
        period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom"
      }
    end

    assert_response :service_unavailable
    assert_equal "application/json", @response.media_type
    json_response = JSON.parse(@response.body)
    assert_equal "UPSTREAM_ERROR", json_response["code"]
    assert_includes json_response["message"], "unexpected error"
  end

  # Upstream returns 4xx non-429 — may indicate API contract changed
  test "should return UPSTREAM_ERROR when API returns 4xx non-429" do
    mock_response = OpenStruct.new(success?: false, code: 400, body: '{}')

    RateApiClient.stub(:get_rate, mock_response) do
      get api_v1_pricing_url, params: {
        period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom"
      }
    end

    assert_response :service_unavailable
    assert_equal "application/json", @response.media_type
    json_response = JSON.parse(@response.body)
    assert_equal "UPSTREAM_ERROR", json_response["code"]
    assert_includes json_response["message"], "unexpected error"
  end
end
