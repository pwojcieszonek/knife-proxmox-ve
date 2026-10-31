# frozen_string_literal: true

require "spec_helper"
require "chef/knife/proxmox_vm_shutdown"
require "knife-proxmox-ve/api"

RSpec.describe Chef::Knife::ProxmoxVmShutdown do
  subject(:command) { described_class.new(["web-01"]) }

  it_behaves_like "a vm power command",
    action: :shutdown, desired: "stopped", initial: "running", api_timeout: true

  it "sets the documented banner" do
    expect(described_class.banner).to eq("knife proxmox vm shutdown NAME_OR_VMID (options)")
  end
end
