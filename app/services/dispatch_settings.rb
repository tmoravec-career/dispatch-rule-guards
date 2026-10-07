# Runtime configuration, loaded and validated at boot. The app refuses to boot (Q9) on an
# invalid rules or roster file (the engine's own validation), an unknown API token role,
# a non-numeric rate limit, or a webhook URL without a signing secret.
#
# Values live in Rails.configuration.x.dispatch, so development code reloading keeps
# them. Tests replace them per scenario and call reset! afterwards. The override setters
# (rules=, api_tokens=, webhook_url=, webhook_secret=, configure_rate_limit) are test-only,
# like ClaimDispatcher's race seam: outside the test environment they raise, so no code
# path can swap the live rules, tokens or webhook target (BUG-026).
module DispatchSettings
  ROLES = %w[ops adjuster].freeze
  # Development gets fixed tokens so the API is usable out of the box; nowhere else does.
  DEVELOPMENT_TOKENS = "dev-ops-token:ops,dev-adjuster-token:adjuster".freeze
  # Q48: high enough never to trigger in test, development and load runs.
  UNTHROTTLED_LIMIT = 1_000_000

  class InvalidConfig < StandardError; end

  class << self
    def load!(env = ENV)
      boot = store.boot = ActiveSupport::OrderedOptions.new
      boot.rules_path = env.fetch("DISPATCH_RULES_PATH") { Rails.root.join("config/dispatch_rules.json").to_s }
      boot.adjusters_path = env.fetch("DISPATCH_ADJUSTERS_PATH") { Rails.root.join("config/adjusters.json").to_s }
      boot.rules = Dispatch::RulesConfig.load_file(boot.rules_path)
      boot.roster = Dispatch::Roster.load_file(boot.adjusters_path)
      boot.api_tokens = parse_tokens(env.fetch("DISPATCH_API_TOKENS") { Rails.env.development? ? DEVELOPMENT_TOKENS : "" })
      boot.rate_limit = positive_integer(env, "DISPATCH_RATE_LIMIT", Rails.env.production? ? 600 : UNTHROTTLED_LIMIT)
      boot.rate_window = positive_integer(env, "DISPATCH_RATE_WINDOW", 60)
      boot.webhook_url = env["DISPATCH_WEBHOOK_URL"].presence
      boot.webhook_secret = env["DISPATCH_WEBHOOK_SECRET"].presence
      boot.test_latency_ms = parse_test_latency(env)
      if boot.webhook_url
        check_webhook_url!(boot.webhook_url)
        unless boot.webhook_secret
          raise InvalidConfig, "DISPATCH_WEBHOOK_URL is set but DISPATCH_WEBHOOK_SECRET is not: every delivery must be signed (Q45)"
        end
      end
      start_webhook_queue
      reset!
    # Every problem, including an unreadable rules or roster file, gets the same message.
    rescue Dispatch::ConfigError, InvalidConfig, SystemCallError => e
      raise InvalidConfig, "refusing to boot with invalid dispatch config (Q9):\n#{e.message}"
    end

    # Back to the values loaded at boot.
    def reset!
      boot = store.boot
      store.rules = boot.rules
      store.api_tokens = boot.api_tokens.dup
      install_rate_limiter(limit: boot.rate_limit, window_seconds: boot.rate_window)
      store.webhook_url = boot.webhook_url
      store.webhook_secret = boot.webhook_secret
    end

    # The active rules. Re-dispatch always uses these, not the rules at first dispatch (Q19).
    def rules
      store.rules
    end

    def rules=(config)
      test_only!(:rules=)
      raise ArgumentError, "expected a Dispatch::RulesConfig" unless config.is_a?(Dispatch::RulesConfig)

      store.rules = config
    end

    # The validated roster file; db/seeds.rb loads it into the adjusters table.
    def roster
      store.boot.roster
    end

    # {token => role}
    def api_tokens
      store.api_tokens
    end

    def api_tokens=(tokens)
      test_only!(:api_tokens=)
      bad = tokens.values - ROLES
      raise ArgumentError, "unknown API token role(s): #{bad.join(', ')}" unless bad.empty?
      raise ArgumentError, "an API token contains whitespace" if tokens.keys.any? { |t| t.to_s.match?(/\s/) || t.to_s.empty? }

      store.api_tokens = tokens.dup
    end

    def rate_limiter
      store.rate_limiter
    end

    def configure_rate_limit(limit:, window_seconds:)
      test_only!(:configure_rate_limit)
      install_rate_limiter(limit: limit, window_seconds: window_seconds)
    end

    def webhook_url
      store.webhook_url
    end

    def webhook_url=(url)
      test_only!(:webhook_url=)
      check_webhook_url!(url) if url
      store.webhook_url = url
    end

    def webhook_secret
      store.webhook_secret
    end

    def webhook_secret=(secret)
      test_only!(:webhook_secret=)
      store.webhook_secret = secret
    end

    # Off the request thread everywhere except test, where delivery is inline so scenarios
    # are deterministic (Q57).
    def webhook_delivery
      Rails.env.test? ? :inline : :async
    end

    def webhook_queue
      store.webhook_queue
    end

    # Milliseconds added to every API response, from DISPATCH_TEST_LATENCY_MS (default 0).
    # A test-only setting for the k6 latency-breach scenarios (STEP_GLOSSARY.md section 9):
    # production refuses to boot with it set.
    def test_latency_ms
      store.boot.test_latency_ms
    end

    private

    def store
      Rails.configuration.x.dispatch
    end

    def test_only!(setter)
      return if Rails.env.test?

      raise ArgumentError, "DispatchSettings.#{setter} is a test-only override (Rails.env is #{Rails.env}); "                            "configure the app through the environment (docs/CONFIGURATION.md)"
    end

    def install_rate_limiter(limit:, window_seconds:)
      store.rate_limiter = RateLimiter.new(limit: limit, window_seconds: window_seconds)
    end

    # Q57: an absolute http or https URL with a host.
    def check_webhook_url!(url)
      uri = URI.parse(url)
      return if uri.is_a?(URI::HTTP) && uri.host.present?

      raise InvalidConfig, "DISPATCH_WEBHOOK_URL must be an absolute http or https URL"
    rescue URI::InvalidURIError
      raise InvalidConfig, "DISPATCH_WEBHOOK_URL must be an absolute http or https URL"
    end

    # One queue per process. Each job delivers with the URL and secret current when the
    # event committed; at exit, queued deliveries get a few seconds to finish.
    def start_webhook_queue
      return if store.webhook_queue

      store.webhook_queue = WebhookQueue.new do |job|
        Rails.application.executor.wrap do
          event = DispatchEvent.find_by(id: job.fetch(:event_id))
          WebhookNotifier.new(url: job.fetch(:url), secret: job.fetch(:secret)).deliver(event) if event
        end
      end
      queue = store.webhook_queue
      at_exit { queue.shutdown(timeout: 5) }
    end

    # "token:role,token:role". Space around the commas is allowed; a token containing
    # whitespace or listed twice refuses to boot (Q57). Messages name the entry by position,
    # never the token itself.
    def parse_tokens(text)
      text.split(",").map(&:strip).reject(&:empty?).each_with_index.with_object({}) do |(pair, i), tokens|
        entry = "DISPATCH_API_TOKENS entry #{i + 1}"
        token, role = pair.split(":", 2)
        role = role.to_s.strip
        raise InvalidConfig, "#{entry}: expected token:role" if token.to_s.empty? || role.empty?
        raise InvalidConfig, "#{entry}: the token contains whitespace" if token.match?(/\s/)
        raise InvalidConfig, "#{entry}: unknown role #{role.inspect} (allowed: #{ROLES.join(', ')})" unless ROLES.include?(role)
        raise InvalidConfig, "#{entry}: the token is listed more than once" if tokens.key?(token)

        tokens[token] = role
      end
    end

    def parse_test_latency(env)
      raw = env["DISPATCH_TEST_LATENCY_MS"].presence or return 0
      if Rails.env.production?
        raise InvalidConfig, "DISPATCH_TEST_LATENCY_MS is a test-only setting and is refused in production"
      end

      value = Integer(raw, 10, exception: false)
      raise InvalidConfig, "DISPATCH_TEST_LATENCY_MS must be a whole number of milliseconds >= 0, got #{raw.inspect}" unless value && value >= 0

      value
    end

    def positive_integer(env, name, default)
      raw = env.fetch(name) { return default }
      value = Integer(raw, 10, exception: false)
      raise InvalidConfig, "#{name} must be a positive integer, got #{raw.inspect}" unless value&.positive?

      value
    end
  end
end
