# frozen_string_literal: true

require "spec_helper"
require "knife-proxmox-ve/api"
require "knife-proxmox-ve/client"
require "knife-proxmox-ve/errors"

RSpec.describe Knife::Proxmox::Api do
  let(:host) { "pve1.test" }
  let(:port) { 8006 }
  let(:token_id) { "knife@pve!automation" }
  let(:token_secret) { "00000000-1111-2222-3333-444444444444" }
  let(:base) { "https://#{host}:#{port}/api2/json" }

  let(:client) do
    Knife::Proxmox::Client.new(host:, token_id:, token_secret:, port:)
  end

  subject(:api) { described_class.new(client) }

  def stub_cluster_resources
    stub_request(:get, "#{base}/cluster/resources")
      .with(query: { "type" => "vm" })
      .to_return(status: 200, body: ProxmoxResponses.cluster_resources)
  end

  describe "#find_template" do
    before { stub_cluster_resources }

    it "matches a template by name and returns symbol-keyed identity" do
      expect(api.find_template("ubuntu-2404-template"))
        .to eq(vmid: 9000, node: "pve1", name: "ubuntu-2404-template")
    end

    it "matches a template by numeric vmid (given as Integer or String)" do
      expect(api.find_template(9000)[:vmid]).to eq(9000)
      expect(api.find_template("9000")[:vmid]).to eq(9000)
    end

    it "ignores non-template qemu VMs even when the vmid matches" do
      expect { api.find_template(101) }.to raise_error(Knife::Proxmox::NotFoundError)
    end

    it "never matches an lxc resource (qemu filter)" do
      expect { api.find_template("ct-dns") }.to raise_error(Knife::Proxmox::NotFoundError)
    end

    it "raises NotFoundError when no template matches" do
      expect { api.find_template("does-not-exist") }
        .to raise_error(Knife::Proxmox::NotFoundError, /does-not-exist/)
    end
  end

  describe "#list_resources" do
    before { stub_cluster_resources }

    it "drops lxc and keeps only qemu entries" do
      result = api.list_resources
      expect(result.map { |r| r[:vmid] }).to contain_exactly(9000, 101)
    end

    it "narrows to templates with template: true" do
      result = api.list_resources(template: true)
      expect(result.map { |r| r[:vmid] }).to eq([9000])
    end

    it "narrows to non-templates with template: false" do
      result = api.list_resources(template: false)
      expect(result.map { |r| r[:vmid] }).to eq([101])
    end

    it "normalizes missing fields to nil" do
      web = api.list_resources(template: false).first
      expect(web).to include(vmid: 101, status: "running", uptime: 3600)
      expect(web[:maxdisk]).to be_nil
    end
  end

  describe "#next_id" do
    it "coerces the string payload to an Integer" do
      stub_request(:get, "#{base}/cluster/nextid")
        .to_return(status: 200, body: ProxmoxResponses.next_id(9001))

      expect(api.next_id).to eq(9001)
    end
  end

  describe "#clone" do
    it "posts newid plus params to the node's qemu clone path and returns the UPID" do
      stub = stub_request(:post, "#{base}/nodes/pve1/qemu/9000/clone")
        .with(body: { "newid" => "9001", "name" => "web-02", "full" => "1" })
        .to_return(status: 200, body: ProxmoxResponses.wrap(ProxmoxResponses.upid))

      result = api.clone(node: "pve1", vmid: 9000, newid: 9001, name: "web-02", full: 1)

      expect(stub).to have_been_requested
      expect(result).to eq(ProxmoxResponses.upid)
    end

    it "encodes the node name into the path segment" do
      stub = stub_request(:post, "#{base}/nodes/pve%2Fweird/qemu/9000/clone")
        .to_return(status: 200, body: ProxmoxResponses.wrap(ProxmoxResponses.upid))

      api.clone(node: "pve/weird", vmid: 9000, newid: 9001)

      expect(stub).to have_been_requested
    end
  end

  describe "#update_config" do
    it "posts only the supplied keys" do
      stub = stub_request(:post, "#{base}/nodes/pve1/qemu/9001/config")
        .with(body: { "cores" => "2", "memory" => "2048", "ipconfig0" => "ip=dhcp" })
        .to_return(status: 200, body: ProxmoxResponses.wrap(nil))

      api.update_config(node: "pve1", vmid: 9001, cores: 2, memory: 2048, ipconfig0: "ip=dhcp")

      expect(stub).to have_been_requested
    end
  end

  describe "#start" do
    it "posts to status/start and returns the UPID" do
      stub = stub_request(:post, "#{base}/nodes/pve1/qemu/9001/status/start")
        .to_return(status: 200, body: ProxmoxResponses.wrap(ProxmoxResponses.upid(type: "qmstart")))

      result = api.start(node: "pve1", vmid: 9001)

      expect(stub).to have_been_requested
      expect(result).to eq(ProxmoxResponses.upid(type: "qmstart"))
    end
  end

  describe "#vm_config" do
    it "returns the config Hash" do
      stub_request(:get, "#{base}/nodes/pve1/qemu/9001/config")
        .to_return(status: 200, body: ProxmoxResponses.wrap("ide2" => "local-lvm:cloudinit", "cores" => 2))

      expect(api.vm_config(node: "pve1", vmid: 9001)).to include("ide2" => "local-lvm:cloudinit")
    end
  end

  describe "#agent_ip_addresses" do
    it "skips loopback and link-local and returns the real IPv4" do
      stub_request(:get, "#{base}/nodes/pve1/qemu/9001/agent/network-get-interfaces")
        .to_return(status: 200, body: ProxmoxResponses.agent_interfaces(ip: "10.0.10.50"))

      expect(api.agent_ip_addresses(node: "pve1", vmid: 9001)).to eq(["10.0.10.50"])
    end

    it "orders IPv4 before any surviving IPv6 address" do
      body = ProxmoxResponses.wrap(
        "result" => [
          { "name" => "lo", "ip-addresses" => [{ "ip-address" => "127.0.0.1" }] },
          { "name" => "eth0", "ip-addresses" => [
            { "ip-address" => "2001:db8::5", "ip-address-type" => "ipv6" },
            { "ip-address" => "10.0.10.50", "ip-address-type" => "ipv4" },
          ] },
        ]
      )
      stub_request(:get, "#{base}/nodes/pve1/qemu/9001/agent/network-get-interfaces")
        .to_return(status: 200, body:)

      expect(api.agent_ip_addresses(node: "pve1", vmid: 9001)).to eq(["10.0.10.50", "2001:db8::5"])
    end

    it "raises when the guest agent is not available (404)" do
      stub_request(:get, "#{base}/nodes/pve1/qemu/9001/agent/network-get-interfaces")
        .to_return(status: 404, body: "")

      expect { api.agent_ip_addresses(node: "pve1", vmid: 9001) }
        .to raise_error(Knife::Proxmox::NotFoundError)
    end
  end

  describe "#wait_task" do
    let(:upid) { ProxmoxResponses.upid(node: "pve1") }
    let(:enc_upid) { Knife::Proxmox::Client.encode_segment(upid) }

    it "parses the node from the UPID and polls that node's task path" do
      stub = stub_request(:get, "#{base}/nodes/pve1/tasks/#{enc_upid}/status")
        .to_return(status: 200, body: ProxmoxResponses.task_status(running: false, exitstatus: "OK"))

      expect(api.wait_task(upid:, sleeper: ->(_) {})).to be(true)
      expect(stub).to have_been_requested
    end

    it "returns true once the task is stopped with exitstatus OK" do
      stub_request(:get, "#{base}/nodes/pve1/tasks/#{enc_upid}/status")
        .to_return(
          { status: 200, body: ProxmoxResponses.task_status(running: true) },
          { status: 200, body: ProxmoxResponses.task_status(running: false, exitstatus: "OK") }
        )

      calls = []
      expect(api.wait_task(upid:, sleeper: ->(s) { calls << s })).to be(true)
      expect(calls).to eq([2])
    end

    it "raises TaskError with a scrubbed log on a non-OK exitstatus" do
      stub_request(:get, "#{base}/nodes/pve1/tasks/#{enc_upid}/status")
        .to_return(status: 200, body: ProxmoxResponses.task_status(running: false, exitstatus: "clone failed"))
      stub_request(:get, "#{base}/nodes/pve1/tasks/#{enc_upid}/log")
        .to_return(status: 200, body: ProxmoxResponses.wrap([
          { "n" => 1, "t" => "starting clone" },
          { "n" => 2, "t" => "update VM 9001: -cipassword hunter2 -cores 2" },
          { "n" => 3, "t" => "error: no space left" },
        ]))

      expect { api.wait_task(upid:, sleeper: ->(_) {}) }
        .to raise_error(Knife::Proxmox::TaskError) do |err|
          expect(err.upid).to eq(upid)
          expect(err.exitstatus).to eq("clone failed")
          expect(err.log).to include("no space left")
          # A cipassword echoed in the task-log body (HTTP 200) must be scrubbed before it
          # reaches TaskError#log and the terminal.
          expect(err.log).not_to include("hunter2")
          expect(err.log).to include("[FILTERED]")
          expect(err.log).not_to include(token_secret)
        end
    end

    it "raises TimeoutError once the monotonic deadline passes (instant via injected clock)" do
      stub_request(:get, "#{base}/nodes/pve1/tasks/#{enc_upid}/status")
        .to_return(status: 200, body: ProxmoxResponses.task_status(running: true))

      # Advance the monotonic clock past the deadline on the second read.
      allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(0.0, 1000.0)

      expect { api.wait_task(upid:, timeout: 5, sleeper: ->(_) {}) }
        .to raise_error(Knife::Proxmox::TimeoutError, /did not finish within 5s/)
    end
  end
end
