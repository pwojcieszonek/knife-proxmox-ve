# frozen_string_literal: true

require "spec_helper"
require "knife-proxmox-ve/provisioner"
require "knife-proxmox-ve/api"
require "knife-proxmox-ve/errors"

RSpec.describe Knife::Proxmox::Provisioner do
  let(:api) { instance_double(Knife::Proxmox::Api) }
  let(:port_check) { ->(_host, _port) { true } }
  let(:sleeper) { ->(_seconds) {} }

  subject(:provisioner) do
    described_class.new(api, port_check:, sleeper:)
  end

  let(:clone_upid) { "UPID:pve1:00001234:00ABCDEF:00000000:qmclone:9000:knife@pve!automation:" }
  let(:start_upid) { "UPID:pve1:00005678:00ABCDEF:00000000:qmstart:9001:knife@pve!automation:" }

  # A cloud-init drive present on the cloned VM (so the drive guard passes).
  let(:ci_config) { { "ide2" => "local-lvm:cloudinit", "cores" => 2 } }

  def base_spec(overrides = {})
    {
      name:          "web-02",
      template:      { vmid: 9000, node: "pve1" },
      newid:         9001,
      target_node:   nil,
      storage:       nil,
      full:          false,
      pool:          nil,
      config:        {},
      clone_timeout: 600,
      boot_timeout:  300,
    }.merge(overrides)
  end

  # Wires the happy-path Api calls that every successful provision makes. Returns nothing;
  # individual examples assert on the relevant call via the `expect(api).to receive`.
  def allow_happy_path(node: "pve1", vmid: 9001, agent_ip: "10.0.10.50")
    allow(api).to receive(:next_id).and_return(vmid)
    allow(api).to receive(:clone).and_return(clone_upid)
    allow(api).to receive(:update_config)
    allow(api).to receive(:start).and_return(start_upid)
    allow(api).to receive(:wait_task).and_return(true)
    allow(api).to receive(:vm_config).and_return(ci_config)
    allow(api).to receive(:agent_ip_addresses).and_return([agent_ip])
  end

  describe "#provision clone + task sequencing" do
    before { allow_happy_path }

    it "clones on the SOURCE node with the template vmid and waits on the clone UPID without a node" do
      expect(api).to receive(:clone)
        .with(hash_including(node: "pve1", vmid: 9000, newid: 9001, name: "web-02"))
        .and_return(clone_upid)
      expect(api).to receive(:wait_task).with(upid: clone_upid, timeout: 600).and_return(true)
      expect(api).to receive(:wait_task).with(upid: start_upid).and_return(true)

      provisioner.provision(base_spec)
    end

    it "uses next_id when newid is nil" do
      allow(api).to receive(:next_id).and_return(9100)
      expect(api).to receive(:clone).with(hash_including(newid: 9100)).and_return(clone_upid)
      allow(api).to receive(:vm_config).and_return(ci_config)
      allow(api).to receive(:agent_ip_addresses).and_return(["10.0.10.50"])

      result = provisioner.provision(base_spec(newid: nil, config: { ip: "dhcp" }))
      expect(result.vmid).to eq(9100)
    end

    it "passes full=1 and storage/pool only when present, omitting nil params" do
      expect(api).to receive(:clone)
        .with(node: "pve1", vmid: 9000, newid: 9001, name: "web-02",
              full: 1, storage: "fast", pool: "infra")
        .and_return(clone_upid)

      provisioner.provision(base_spec(full: true, storage: "fast", pool: "infra"))
    end
  end

  describe "#provision clone collision retry" do
    let(:collision) do
      Knife::Proxmox::ApiError.new("unable to create VM 9101 - config file already exists", status: 500)
    end

    it "retries next_id + clone once when newid was auto-assigned and the id collides" do
      allow(api).to receive(:next_id).and_return(9101, 9102)
      allow(api).to receive(:start).and_return(start_upid)
      allow(api).to receive(:wait_task).and_return(true)
      allow(api).to receive(:update_config)
      allow(api).to receive(:vm_config).and_return(ci_config)
      allow(api).to receive(:agent_ip_addresses).and_return(["10.0.10.50"])

      expect(api).to receive(:clone).with(hash_including(newid: 9101)).and_raise(collision)
      expect(api).to receive(:clone).with(hash_including(newid: 9102)).and_return(clone_upid)

      result = provisioner.provision(base_spec(newid: nil, config: { ip: "dhcp" }))
      expect(result.vmid).to eq(9102)
    end

    it "does NOT retry when newid was supplied explicitly (re-raises the collision)" do
      allow(api).to receive(:clone).and_raise(collision)

      expect { provisioner.provision(base_spec(newid: 9101)) }
        .to raise_error(Knife::Proxmox::ApiError)
      expect(api).to have_received(:clone).once
    end

    it "retries only once, then re-raises if the second attempt also collides" do
      allow(api).to receive(:next_id).and_return(9101, 9102)
      allow(api).to receive(:clone).and_raise(collision)

      expect { provisioner.provision(base_spec(newid: nil)) }
        .to raise_error(Knife::Proxmox::ApiError)
      expect(api).to have_received(:clone).twice
    end
  end

  describe "#provision effective node" do
    it "uses target_node for vm_config/update_config/start when a migration target is set" do
      allow(api).to receive(:next_id).and_return(9001)
      allow(api).to receive(:clone).and_return(clone_upid)
      allow(api).to receive(:wait_task).and_return(true)
      allow(api).to receive(:agent_ip_addresses).and_return(["10.0.10.50"])

      expect(api).to receive(:vm_config).with(node: "pve2", vmid: 9001).and_return(ci_config)
      expect(api).to receive(:update_config).with(hash_including(node: "pve2", vmid: 9001))
      expect(api).to receive(:start).with(node: "pve2", vmid: 9001).and_return(start_upid)

      result = provisioner.provision(base_spec(target_node: "pve2", config: { ciuser: "ubuntu" }))
      expect(result.node).to eq("pve2")
    end
  end

  describe "#provision config param building" do
    before { allow_happy_path }

    def captured_update_params(config)
      captured = nil
      allow(api).to receive(:update_config) { |args| captured = args }
      provisioner.provision(base_spec(config:))
      captured
    end

    it "passes cores/sockets/memory/ciuser/cipassword/nameserver/searchdomain through" do
      params = captured_update_params(
        cores: 2, sockets: 1, memory: 2048, ciuser: "ubuntu", cipassword: "s3cret",
        nameserver: "10.0.0.1", searchdomain: "example.test"
      )
      expect(params).to include(
        cores: 2, sockets: 1, memory: 2048, ciuser: "ubuntu", cipassword: "s3cret",
        nameserver: "10.0.0.1", searchdomain: "example.test"
      )
    end

    it "omits net0 entirely when neither bridge nor vlan is given (preserves template MAC)" do
      params = captured_update_params(cores: 2)
      expect(params).not_to have_key(:net0)
    end

    it "builds net0 with bridge only and no dangling tag=" do
      params = captured_update_params(bridge: "vmbr0")
      expect(params[:net0]).to eq("model=virtio,bridge=vmbr0")
      expect(params[:net0]).not_to include("tag=")
    end

    it "builds net0 with both bridge and vlan tag" do
      params = captured_update_params(bridge: "vmbr0", vlan: 30)
      expect(params[:net0]).to eq("model=virtio,bridge=vmbr0,tag=30")
    end

    it "builds net0 with vlan only (no bridge)" do
      params = captured_update_params(vlan: 30)
      expect(params[:net0]).to eq("model=virtio,tag=30")
    end

    it "builds ipconfig0 for a static IP with prefix and gateway" do
      params = captured_update_params(ip: "10.0.10.50", prefix: 24, gateway: "10.0.10.1")
      expect(params[:ipconfig0]).to eq("ip=10.0.10.50/24,gw=10.0.10.1")
    end

    it "defaults the prefix to 24 when only a bare IP is given" do
      params = captured_update_params(ip: "10.0.10.50")
      expect(params[:ipconfig0]).to eq("ip=10.0.10.50/24")
    end

    it "honors an IP that already carries a CIDR" do
      params = captured_update_params(ip: "10.0.10.50/25", gateway: "10.0.10.1")
      expect(params[:ipconfig0]).to eq("ip=10.0.10.50/25,gw=10.0.10.1")
    end

    it "builds ipconfig0 for dhcp" do
      params = captured_update_params(ip: "dhcp")
      expect(params[:ipconfig0]).to eq("ip=dhcp")
    end

    it "url-encodes the ssh public key (stripped) for sshkeys" do
      params = captured_update_params(ssh_public_key: "  ssh-ed25519 AAAA test@host  ")
      expect(params[:sshkeys]).to eq(ERB::Util.url_encode("ssh-ed25519 AAAA test@host"))
      expect(params[:sshkeys]).to include("%20")
    end

    it "sends no update_config at all when the config is empty" do
      expect(api).not_to receive(:update_config)
      provisioner.provision(base_spec(config: {}))
    end
  end

  describe "#provision cloud-init drive guard" do
    it "raises a clear Error when a cloud-init key is set but no cloud-init drive exists" do
      allow(api).to receive(:next_id).and_return(9001)
      allow(api).to receive(:clone).and_return(clone_upid)
      allow(api).to receive(:wait_task).and_return(true)
      allow(api).to receive(:vm_config).and_return("scsi0" => "local-lvm:vm-9001-disk-0", "cores" => 2)

      expect(api).not_to receive(:update_config)
      expect(api).not_to receive(:start)

      expect { provisioner.provision(base_spec(config: { ciuser: "ubuntu" })) }
        .to raise_error(Knife::Proxmox::Error, /no cloud-init drive/)
    end

    it "passes the guard when the drive is on a scsi/sata/ide controller naming cloudinit" do
      allow_happy_path
      allow(api).to receive(:vm_config).and_return("sata1" => "fast:cloudinit")

      expect { provisioner.provision(base_spec(config: { ciuser: "ubuntu", ip: "dhcp" })) }
        .not_to raise_error
    end

    it "does NOT read vm_config when no cloud-init key is being set (hardware-only update)" do
      allow(api).to receive(:next_id).and_return(9001)
      allow(api).to receive(:clone).and_return(clone_upid)
      allow(api).to receive(:wait_task).and_return(true)
      allow(api).to receive(:update_config)
      allow(api).to receive(:start).and_return(start_upid)
      allow(api).to receive(:agent_ip_addresses).and_return(["10.0.10.50"])

      expect(api).not_to receive(:vm_config)

      provisioner.provision(base_spec(config: { cores: 4, memory: 4096 }))
    end
  end

  describe "#provision IP resolution" do
    it "returns the static spec IP (stripped of CIDR) WITHOUT re-reading vm_config" do
      allow(api).to receive(:next_id).and_return(9001)
      allow(api).to receive(:clone).and_return(clone_upid)
      allow(api).to receive(:wait_task).and_return(true)
      allow(api).to receive(:update_config)
      allow(api).to receive(:vm_config).and_return(ci_config)
      allow(api).to receive(:start).and_return(start_upid)

      expect(api).not_to receive(:agent_ip_addresses)

      result = provisioner.provision(
        base_spec(config: { ip: "10.0.10.77/24", gateway: "10.0.10.1", ciuser: "ubuntu" })
      )
      expect(result.ip).to eq("10.0.10.77")
    end

    it "polls the guest agent for a dhcp address and returns the discovered IPv4" do
      allow_happy_path(agent_ip: "10.0.20.5")

      result = provisioner.provision(base_spec(config: { ip: "dhcp" }))
      expect(result.ip).to eq("10.0.20.5")
    end

    it "keeps polling the agent (via sleeper) until a usable IPv4 appears" do
      allow(api).to receive(:next_id).and_return(9001)
      allow(api).to receive(:clone).and_return(clone_upid)
      allow(api).to receive(:wait_task).and_return(true)
      allow(api).to receive(:start).and_return(start_upid)
      allow(api).to receive(:vm_config).and_return(ci_config)
      allow(api).to receive(:update_config)
      allow(api).to receive(:agent_ip_addresses).and_return([], [], ["10.0.20.5"])

      slept = []
      poller = described_class.new(api, port_check:, sleeper: ->(s) { slept << s })

      result = poller.provision(base_spec(config: { ip: "dhcp" }))
      expect(result.ip).to eq("10.0.20.5")
      expect(slept).not_to be_empty
    end

    it "raises TimeoutError when the agent never reports a usable IPv4 before boot_timeout" do
      allow(api).to receive(:next_id).and_return(9001)
      allow(api).to receive(:clone).and_return(clone_upid)
      allow(api).to receive(:wait_task).and_return(true)
      allow(api).to receive(:start).and_return(start_upid)
      allow(api).to receive(:vm_config).and_return(ci_config)
      allow(api).to receive(:update_config)
      allow(api).to receive(:agent_ip_addresses).and_return([])

      allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(0.0, 1000.0)

      expect { provisioner.provision(base_spec(boot_timeout: 60, config: { ip: "dhcp" })) }
        .to raise_error(Knife::Proxmox::TimeoutError, /no usable IPv4/)
    end

    it "raises TimeoutError when SSH port 22 never opens before the deadline" do
      allow_happy_path
      closed_port = ->(_host, _port) { false }
      prov = described_class.new(api, port_check: closed_port, sleeper:)

      allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(0.0, 1000.0)

      expect { prov.provision(base_spec(config: { ip: "10.0.10.50/24" })) }
        .to raise_error(Knife::Proxmox::TimeoutError, /port 22/)
    end
  end

  describe "#provision wait policy (vm create: wait_for_ssh / require_ip)" do
    it "skips the SSH port wait for a static IP when wait_for_ssh is false" do
      allow(api).to receive(:next_id).and_return(9001)
      allow(api).to receive(:clone).and_return(clone_upid)
      allow(api).to receive(:wait_task).and_return(true)
      allow(api).to receive(:update_config)
      allow(api).to receive(:vm_config).and_return(ci_config)
      allow(api).to receive(:start).and_return(start_upid)

      port_called = false
      prov = described_class.new(api, port_check: ->(_h, _p) { port_called = true; true }, sleeper:)

      result = prov.provision(
        base_spec(wait_for_ssh: false, config: { ip: "10.0.10.50/24", ciuser: "ubuntu" })
      )
      expect(result.ip).to eq("10.0.10.50")
      expect(port_called).to be(false)
    end

    it "returns the agent IP without an SSH port wait for dhcp when wait_for_ssh is false" do
      allow_happy_path(agent_ip: "10.0.20.5")

      port_called = false
      prov = described_class.new(api, port_check: ->(_h, _p) { port_called = true; true }, sleeper:)

      result = prov.provision(base_spec(wait_for_ssh: false, config: { ip: "dhcp" }))
      expect(result.ip).to eq("10.0.20.5")
      expect(port_called).to be(false)
    end

    it "returns a nil IP (no raise) when require_ip is false and the agent never reports one" do
      allow(api).to receive(:next_id).and_return(9001)
      allow(api).to receive(:clone).and_return(clone_upid)
      allow(api).to receive(:wait_task).and_return(true)
      allow(api).to receive(:update_config)
      allow(api).to receive(:vm_config).and_return(ci_config)
      allow(api).to receive(:start).and_return(start_upid)
      allow(api).to receive(:agent_ip_addresses).and_return([])

      allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(0.0, 1000.0)

      result = provisioner.provision(
        base_spec(boot_timeout: 60, wait_for_ssh: false, require_ip: false, config: { ip: "dhcp" })
      )
      expect(result.ip).to be_nil
    end
  end

  describe "#provision result" do
    it "returns a Result struct carrying vmid, node, and ip" do
      allow_happy_path

      result = provisioner.provision(base_spec(config: { ip: "10.0.10.50/24" }))
      expect(result).to be_a(described_class::Result)
      expect(result).to have_attributes(vmid: 9001, node: "pve1", ip: "10.0.10.50")
    end
  end

  describe "#provision progress reporting" do
    it "emits info messages through the ui when one is supplied" do
      allow_happy_path
      ui = instance_double("Chef::Knife::UI")
      allow(ui).to receive(:info)
      allow(ui).to receive(:warn)
      prov = described_class.new(api, ui:, port_check:, sleeper:)

      prov.provision(base_spec(config: { ip: "10.0.10.50/24" }))

      expect(ui).to have_received(:info).with(/Cloning/)
      expect(ui).to have_received(:info).with(/SSH on 10\.0\.10\.50/)
    end
  end
end
