# Rails-layer tests (test/app): the app booted in the test environment, each test in a
# rolled-back transaction, no real outbound HTTP. The engine suite (test/dispatch) needs
# none of this and stays runnable with plain `ruby -Ilib`.
#
#   bundle exec ruby -Itest -e 'Dir["test/app/**/*_test.rb"].each { |f| require "./#{f}" }'
ENV["RAILS_ENV"] = "test"
require_relative "../config/environment"
require "rails/test_help"
require "minitest/mock"
require "webmock/minitest"

module AppTestHelpers
  OPS = "ops-token".freeze
  ADJUSTER = "adjuster-token".freeze

  def setup
    super
    DispatchSettings.reset!
    DispatchSettings.api_tokens = { OPS => "ops", ADJUSTER => "adjuster" }
    DispatchSettings.rules = Dispatch::RulesConfig.from_h(base_rules)
    Adjuster.load_roster!(Dispatch::Roster.from_h({ "adjusters" => background_roster }))
  end

  def teardown
    DispatchSettings.reset!
    Clock.unfreeze
    ClaimDispatcher.after_candidate_selection = nil
    super
  end

  def base_rules
    JSON.parse(File.read(File.expand_path("../config/dispatch_rules.json", __dir__)))
  end

  # The 8-adjuster Background roster from the feature files.
  def background_roster
    JSON.parse(File.read(File.expand_path("../examples/demo_adjusters.json", __dir__)))["adjusters"]
  end

  def claim_attrs(number, lob: "auto", loss: 12_000, vehicle: 30_000, cat: false, state: "TX")
    { "claim_number" => number, "line_of_business" => lob, "estimated_loss" => loss, "vehicle_value" => vehicle,
      "cat_event" => cat, "loss_state" => state }
  end

  def luxury_ca(number)
    claim_attrs(number, vehicle: 120_000, state: "CA")
  end

  def open_claims(id)
    Adjuster.find(id).open_claims
  end
end
