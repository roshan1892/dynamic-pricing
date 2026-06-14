require "test_helper"

class RateApiClientTest < ActiveSupport::TestCase
  # Net::OpenTimeout (slow server) — translated to domain exception TimeoutError
  test "wraps Net::OpenTimeout as TimeoutError" do
    RateApiClient.stub(:post, ->(*) { raise Net::OpenTimeout }) do
      assert_raises(RateApiClient::TimeoutError) do
        RateApiClient.get_rate(period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom")
      end
    end
  end

  # SocketError (server unreachable) — translated to domain exception ConnectionError
  test "wraps SocketError as ConnectionError" do
    RateApiClient.stub(:post, ->(*) { raise SocketError }) do
      assert_raises(RateApiClient::ConnectionError) do
        RateApiClient.get_rate(period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom")
      end
    end
  end
end
