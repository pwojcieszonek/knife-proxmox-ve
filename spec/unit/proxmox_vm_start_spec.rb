# frozen_string_literal: true

require "spec_helper"
require "chef/knife/proxmox_vm_start"
require "knife-proxmox-ve/api"

RSpec.describe Chef::Knife::ProxmoxVmStart do
  subject(:command) { described_class.new(["web-01"]) }

  it_behaves_like "a vm power command", action: :start, desired: "running", initial: "stopped"

  it "sets the documented banner" do
    expect(described_class.banner).to eq("knife proxmox vm start NAME_OR_VMID (options)")
  end
end
