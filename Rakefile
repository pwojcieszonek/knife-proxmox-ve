# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec) do |t|
  t.pattern = "spec/**/*_spec.rb"
end

begin
  require "chefstyle"
  require "rubocop/rake_task"
  RuboCop::RakeTask.new(:style) do |task|
    task.options += ["--display-cop-names", "--no-color"]
  end
rescue LoadError
  desc "Run chefstyle (unavailable — run via `cinc exec rake`)"
  task :style do
    abort "chefstyle is not installed; run the suite under cinc: `cinc exec rake`."
  end
end

task default: %i{style spec}
