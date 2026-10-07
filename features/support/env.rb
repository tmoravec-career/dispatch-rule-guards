# Acceptance suite bootstrap.
#
# @engine and @cli scenarios drive the plain-Ruby engine and the gate CLI only: they never
# touch the database, and the gate runs as a no-bundle subprocess that never loads Rails
# (rule_change_gate.feature checks that). @api, @ui and @load scenarios drive the Rails
# app, booted here in the test environment (features/support/app_world.rb).
$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)

require "cucumber/rails"
require "dispatch"
require "json"
require "fileutils"
require "tmpdir"
require "minitest"

# Minitest assertions inside step definitions, without minitest/autorun.
module AssertionsWorld
  include Minitest::Assertions
  attr_writer :assertions

  def assertions
    @assertions ||= 0
  end
end

World(AssertionsWorld)
