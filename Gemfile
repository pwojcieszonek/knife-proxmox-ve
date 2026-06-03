# frozen_string_literal: true

source "https://rubygems.org"

gemspec

group :development, :test do
  gem "rake", ">= 13.0"
  # The suite loads `chef` (and chef/knife pulls chef/workstation_config_loader); declare it
  # explicitly rather than relying on it arriving transitively through knife.
  gem "chef", ">= 19"
  gem "rspec", "~> 3.12"
  gem "webmock", "~> 3.0"
  gem "rexml" # webmock/crack loads an XML parser that needs rexml on Ruby 3.4+
  gem "chefstyle", "~> 2.2"
end
