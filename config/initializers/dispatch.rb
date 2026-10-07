# Load and validate the rules, roster, tokens, rate limit and webhook settings at boot.
# Anything invalid raises, so the app refuses to boot (Q9).
Rails.application.config.after_initialize do
  DispatchSettings.load!
end
