# frozen_string_literal: true

require "spec_helper"
require "knife-proxmox-ve/provisioner"
require "knife-proxmox-ve/api"
require "knife-proxmox-ve/client"
require "knife-proxmox-ve/errors"

# End-to-end of the Proxmox API sequence: a REAL Provisioner over a REAL Api over a REAL
# Client, with every HTTP round-trip stubbed by webmock. This proves the three library
# modules integrate (path shapes, body encoding, the clone -> configure -> start -> wait
# ordering, the cloud-init drive guard). SSH/bootstrap are out of scope; the static-IP
# path is used so wait_for_ip never polls the guest agent.
RSpec.describe "vm provision flow", type: :functional do
  let(:host) { "pve1.test" }
  let(:port) { 8006 }
  let(:token_id) { "knife@pve!automation" }
  let(:token_secret) { "00000000-1111-2222-3333-444444444444" }
  let(:base) { "https://#{host}:#{port}/api2/json" }

  let(:client) do
    Knife::Proxmox::Client.new(host:, token_id:, token_secret:, port:)
  end
  let(:api) { Knife::Proxmox::Api.new(client) }

  # No real sockets, no real sleeps: the port is always open, sleeps are no-ops.
  subject(:provisioner) do
    Knife::Proxmox::Provisioner.new(
      api,
      port_check: ->(_host, _port) { true },
      sleeper:    ->(_seconds) {}
    )
  end

  let(:clone_upid) { ProxmoxResponses.upid(node: "pve1", type: "qmclone") }
  let(:start_upid) { ProxmoxResponses.upid(node: "pve1", type: "qmstart") }

  def enc(upid)
    Knife::Proxmox::Client.encode_segment(upid)
  end

  def task_status_ok(upid)
    ProxmoxResponses.wrap("upid" => upid, "status" => "stopped", "exitstatus" => "OK")
  end

  # Stub the full happy path. Returns the request stubs that must have fired.
  def stub_happy_path(vm_config_body:)
    cluster = stub_request(:get, "#{base}/cluster/resources")
      .with(query: { "type" => "vm" })
      .to_return(status: 200, body: ProxmoxResponses.cluster_resources)

    nextid = stub_request(:get, "#{base}/cluster/nextid")
      .to_return(status: 200, body: ProxmoxResponses.next_id(9001))

    clone = stub_request(:post, "#{base}/nodes/pve1/qemu/9000/clone")
      .with(body: hash_including("newid" => "9001", "name" => "web-02"))
      .to_return(status: 200, body: ProxmoxResponses.wrap(clone_upid))

    clone_task = stub_request(:get, "#{base}/nodes/pve1/tasks/#{enc(clone_upid)}/status")
      .to_return(status: 200, body: task_status_ok(clone_upid))

    read_config = stub_request(:get, "#{base}/nodes/pve1/qemu/9001/config")
      .to_return(status: 200, body: vm_config_body)

    write_config = stub_request(:post, "#{base}/nodes/pve1/qemu/9001/config")
      .with(body: hash_including("ipconfig0" => "ip=10.0.10.50/24"))
      .to_return(status: 200, body: ProxmoxResponses.wrap(nil))

    start = stub_request(:post, "#{base}/nodes/pve1/qemu/9001/status/start")
      .to_return(status: 200, body: ProxmoxResponses.wrap(start_upid))

    start_task = stub_request(:get, "#{base}/nodes/pve1/tasks/#{enc(start_upid)}/status")
      .to_return(status: 200, body: task_status_ok(start_upid))

    {
      cluster:, nextid:, clone:, clone_task:,
      read_config:, write_config:, start:, start_task:
    }
  end

  # The spec the Provisioner consumes. Template is resolved through the real Api so the
  # /cluster/resources round-trip is part of the integration.
  def build_spec
    {
      template:      api.find_template("ubuntu-2404-template"),
      name:          "web-02",
      clone_timeout: 120,
      boot_timeout:  60,
      config:        { ip: "10.0.10.50/24", ciuser: "ubuntu" },
    }
  end

  it "drives clone -> configure -> start -> wait and returns the VM identity" do
    stubs = stub_happy_path(
      vm_config_body: ProxmoxResponses.wrap("ide2" => "local-lvm:cloudinit")
    )

    result = provisioner.provision(build_spec)

    expect(result).to have_attributes(vmid: 9001, node: "pve1", ip: "10.0.10.50")

    # Prove the whole sequence actually hit the wire, in shape.
    stubs.each_value { |stub| expect(stub).to have_been_requested }
  end

  it "raises before booting when the template has no cloud-init drive" do
    # No ide2/scsi/sata "...:cloudinit" entry -> the guard must fire.
    no_cloudinit = stub_request(:get, "#{base}/nodes/pve1/qemu/9001/config")
      .to_return(status: 200, body: ProxmoxResponses.wrap("ide0" => "local-lvm:vm-9001-disk-0"))

    stub_request(:get, "#{base}/cluster/resources")
      .with(query: { "type" => "vm" })
      .to_return(status: 200, body: ProxmoxResponses.cluster_resources)
    stub_request(:get, "#{base}/cluster/nextid")
      .to_return(status: 200, body: ProxmoxResponses.next_id(9001))
    stub_request(:post, "#{base}/nodes/pve1/qemu/9000/clone")
      .to_return(status: 200, body: ProxmoxResponses.wrap(clone_upid))
    stub_request(:get, "#{base}/nodes/pve1/tasks/#{enc(clone_upid)}/status")
      .to_return(status: 200, body: task_status_ok(clone_upid))

    # If the guard works, start is never POSTed; webmock would raise on an unstubbed call.
    expect { provisioner.provision(build_spec) }
      .to raise_error(Knife::Proxmox::Error, /no cloud-init drive/)
    expect(no_cloudinit).to have_been_requested
  end
end
