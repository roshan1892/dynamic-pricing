module StructuredLogging
  def log_event(level, **fields)
    context = respond_to?(:log_context, true) ? log_context : {}
    event = fields.delete(:event)
    Rails.logger.public_send(level, {
      timestamp: Time.current.utc.iso8601(3),
      request_id: Thread.current[:request_id],
      event: event
    }.merge(context).merge(fields).to_json)
  end

  def elapsed_ms(start_time)
    ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round
  end
end
