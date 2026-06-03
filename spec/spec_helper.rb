# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "chef"
require "chef/knife"
# crack (webmock's XML parser dep) reopens REXML::ParseException without requiring the
# file that defines it; load rexml first so webmock loads cleanly on Ruby 3.4+.
require "rexml/document"
require "webmock/rspec"

# Shared fixtures/helpers. NOTE: spec_helper intentionally does NOT eager-require the
# gem's lib files — each spec requires only its own subject. This keeps specs independent
# and avoids load-order coupling between files.
Dir[File.expand_path("support/**/*.rb", __dir__)].sort.each { |f| require f }

WebMock.disable_net_connect!(allow_localhost: false)

RSpec.configure do |config|
  config.before(:each) do
    Chef::Config.reset
    Chef::Config[:knife] = {}
  end

  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.mock_with(:rspec) { |m| m.verify_partial_doubles = true }
  config.order = :random
  Kernel.srand config.seed
end
