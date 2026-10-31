# frozen_string_literal: true

require "spec_helper"
require "chef/knife/proxmox_vm_stop"
require "knife-proxmox-ve/api"

RSpec.describe Chef::Knife::ProxmoxVmStop do
  subject(:command) { described_class.new(["web-01"]) }

  it_behaves_like "a vm power command", action: :stop, desired: "stopped", initial: "running"

  it "sets the documented banner" do
    expect(described_class.banner).to eq("knife proxmox vm stop NAME_OR_VMID (options)")
  end
end
