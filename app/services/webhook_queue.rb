# Runs webhook deliveries off the request thread (Q57), so an API response never waits on
# a webhook: an in-process queue with one worker thread, started on first use. Until its
# job runs, an event's webhook_status is "pending".
#
# In-process only: a delivery still queued when the process stops is lost and stays
# pending. A transactional outbox with retries is future work (Q57).
class WebhookQueue
  STOP = Object.new.freeze

  def initialize(logger: Rails.logger, &handler)
    @handler = handler
    @logger = logger
    @jobs = Queue.new
    @mutex = Mutex.new
    @worker = nil
  end

  def enqueue(job)
    start
    @jobs << job
  end

  # Lets queued jobs finish, waiting at most `timeout` seconds.
  def shutdown(timeout:)
    worker = @mutex.synchronize { @worker }
    return unless worker&.alive?

    @jobs << STOP
    worker.join(timeout)
  end

  private

  def start
    @mutex.synchronize do
      @worker = Thread.new { work } unless @worker&.alive?
    end
  end

  def work
    loop do
      job = @jobs.pop
      break if job.equal?(STOP)

      begin
        @handler.call(job)
      rescue StandardError => e
        @logger.error("webhook queue: #{e.class}: #{e.message}")
      end
    end
  end
end
