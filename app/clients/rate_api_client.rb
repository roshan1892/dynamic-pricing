class RateApiClient
  include HTTParty
  base_uri ENV.fetch('RATE_API_URL', 'http://localhost:8080')
  headers "Content-Type" => "application/json"
  headers 'token' => ENV.fetch('RATE_API_TOKEN', '04aa6f42aa03f220c2ae9a276cd68c62')
  open_timeout 5   # fail fast if the server is unreachable
  read_timeout 15  # allow extra time — the upstream model is computationally expensive

  # Domain-level exceptions — callers deal with these, never with transport-level ones
  class TimeoutError < StandardError; end
  class ConnectionError < StandardError; end

  def self.get_rate(period:, hotel:, room:)
    params = {
      attributes: [
        {
          period: period,
          hotel: hotel,
          room: room
        }
      ]
    }.to_json
    self.post("/pricing", body: params)
  rescue Net::OpenTimeout, Net::ReadTimeout
    raise TimeoutError
  rescue SocketError, Errno::ECONNREFUSED
    raise ConnectionError
  end
end
