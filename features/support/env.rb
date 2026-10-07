# Acceptance suite bootstrap. Phase 2 drives the plain-Ruby engine and the gate CLI
# only; nothing here boots Rails or touches a database.
$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)

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
