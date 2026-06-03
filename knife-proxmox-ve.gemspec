# frozen_string_literal: true

lib = File.expand_path("lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "knife-proxmox-ve/version"

Gem::Specification.new do |spec|
  spec.name        = "knife-proxmox-ve"
  spec.version     = Knife::Proxmox::VERSION
  spec.authors     = ["Piotr Wojcieszonek"]
  spec.email       = ["piotr@wojcieszonek.pl"]

  spec.summary     = "Knife plugin to create and automatically bootstrap Proxmox VE VMs with Chef/CINC."
  spec.description  = <<~DESC
    Extends knife with `knife proxmox vm create` to create a new VM on Proxmox VE and
    `knife proxmox vm bootstrap` to create it and automatically bootstrap it with
    Chef/CINC in a single command — cloning a prepared template, configuring
    CPU/RAM/network/cloud-init, starting the VM and waiting for it to boot before
    running the node bootstrap. Adds read-only `cluster list`, `template list` and
    `vm list` helpers. Supports multiple Proxmox clusters defined in ~/.cinc/config.rb
    and authenticates with Proxmox VE API tokens.
  DESC
  spec.homepage = "https://github.com/pwojcieszonek/knife-proxmox-ve"
  spec.license  = "Apache-2.0"
  spec.required_ruby_version = ">= 3.1"

  spec.metadata = {
    "rubygems_mfa_required" => "true",
  }

  spec.files = Dir["lib/**/*.rb"] + %w{LICENSE README.md CHANGELOG.md}
  spec.require_paths = ["lib"]

  # knife is its own gem since Chef 18; the plugin depends on it, not on `chef`.
  # The Proxmox HTTP client uses only the Ruby stdlib (net/http, json, openssl),
  # so there is no faraday/rest-client runtime dependency.
  # Tested against knife 18–19; cap before the next major to avoid an unvetted break.
  spec.add_dependency "knife", ">= 18", "< 21"
end
