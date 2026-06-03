# frozen_string_literal: true

require "spec_helper"
require "tempfile"
require "knife-proxmox-ve/api"
require "knife-proxmox-ve/provisioner"
require "chef/knife/proxmox_vm_create"

RSpec.describe Chef::Knife::ProxmoxVmCreate do
  subject(:kpc) { described_class.new }

  let(:api) { instance_double(Knife::Proxmox::Api) }
  let(:provisioner) do
    instance_double(
      Knife::Proxmox::Provisioner,
      provision: Knife::Proxmox::Provisioner::Result.new(vmid: 9001, node: "pve1", ip: "10.0.10.50")
    )
  end

  let(:public_key_path) do
    file = Tempfile.new(["id_ed25519", ".pub"])
    file.write("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA test@host\n")
    file.flush
    file.path
  end

  before do
    SharedConfig.install!

    allow(kpc.ui).to receive(:fatal!) { |msg| raise SystemExit, msg }
    allow(kpc.ui).to receive(:info)
    allow(kpc.ui).to receive(:warn)
    allow(kpc.ui).to receive(:color) { |text, _| text }

    allow(kpc).to receive(:proxmox_api).and_return(api)
    allow(api).to receive(:find_template)
      .and_return(vmid: 9000, node: "pve1", name: "ubuntu-2404-template")
    allow(Knife::Proxmox::Provisioner).to receive(:new).and_return(provisioner)

    kpc.name_args = ["web-01"]
    kpc.config[:template] = "ubuntu-2404-template"
  end

  describe "command wiring" do
    it "subclasses plain Knife, NOT Bootstrap (no post-provision lifecycle)" do
      expect(described_class.ancestors).to include(Chef::Knife)
      expect(described_class.ancestors).not_to include(Chef::Knife::Bootstrap)
    end

    it "mixes in the shared Proxmox base and provisioning concerns" do
      expect(described_class.ancestors).to include(Chef::Knife::ProxmoxBase)
      expect(described_class.ancestors).to include(Chef::Knife::ProxmoxVmProvision)
    end

    it "declares the shared provisioning options" do
      expect(described_class.options).to include(:template, :newid, :linked_clone, :cipassword)
    end

    it "sets a NAME banner" do
      expect(described_class.banner).to match(/vm create NAME/)
    end

    it "does NOT inherit any bootstrap connection option" do
      expect(described_class.options).not_to include(:connection_protocol)
    end
  end

  describe "#run" do
    it "provisions and prints the VM summary" do
      kpc.run

      expect(kpc.ui).to have_received(:info).with(/VM name: web-01/)
      expect(kpc.ui).to have_received(:info).with(/VMID: 9001/)
      expect(kpc.ui).to have_received(:info).with(/Node: pve1/)
      expect(kpc.ui).to have_received(:info).with(/IP: 10\.0\.10\.50/)
    end

    it "does NOT print a Chef node line (no bootstrap)" do
      kpc.run

      expect(kpc.ui).not_to have_received(:info).with(/Chef node/)
    end

    it "fatals when the VM name is missing" do
      kpc.name_args = []

      expect { kpc.run }.to raise_error(SystemExit)
      expect(kpc.ui).to have_received(:fatal!).with(/VM NAME/)
    end

    it "fatals when --template is missing" do
      kpc.config[:template] = nil

      expect { kpc.run }.to raise_error(SystemExit)
      expect(kpc.ui).to have_received(:fatal!).with(/template/)
    end

    it "coerces string CLI timeouts to integers (regression: --boot-timeout 180 reached the provisioner as a String)" do
      kpc.config[:clone_timeout] = "600"
      kpc.config[:boot_timeout] = "180"

      expect(provisioner).to receive(:provision) do |spec|
        expect(spec[:clone_timeout]).to eq(600)
        expect(spec[:boot_timeout]).to eq(180)
        Knife::Proxmox::Provisioner::Result.new(vmid: 9001, node: "pve1", ip: "10.0.10.50")
      end

      kpc.run
    end

    it "fatals on a non-integer --boot-timeout" do
      kpc.config[:boot_timeout] = "soon"

      expect { kpc.run }.to raise_error(SystemExit)
      expect(kpc.ui).to have_received(:fatal!).with(/boot-timeout must be an integer/)
    end

    it "tells the provisioner NOT to wait for SSH nor require an IP (it never connects)" do
      expect(provisioner).to receive(:provision) do |spec|
        expect(spec[:wait_for_ssh]).to be(false)
        expect(spec[:require_ip]).to be(false)
        Knife::Proxmox::Provisioner::Result.new(vmid: 9001, node: "pve1", ip: "10.0.10.50")
      end

      kpc.run
    end

    it "still reports a VM whose IP came back nil (best-effort IP, omitted from summary)" do
      allow(provisioner).to receive(:provision)
        .and_return(Knife::Proxmox::Provisioner::Result.new(vmid: 9001, node: "pve1", ip: nil))

      kpc.run

      expect(kpc.ui).to have_received(:info).with(/VMID: 9001/)
      expect(kpc.ui).not_to have_received(:info).with(/^IP:/)
    end

    it "drives the provisioner with cluster-default storage/bridge" do
      expect(Knife::Proxmox::Provisioner).to receive(:new).with(api, ui: kpc.ui).and_return(provisioner)
      expect(provisioner).to receive(:provision) do |spec|
        expect(spec[:name]).to eq("web-01")
        expect(spec[:template]).to eq(vmid: 9000, node: "pve1", name: "ubuntu-2404-template")
        expect(spec[:storage]).to eq("local-lvm")
        expect(spec[:config][:bridge]).to eq("vmbr0")
        Knife::Proxmox::Provisioner::Result.new(vmid: 9001, node: "pve1", ip: "10.0.10.50")
      end

      kpc.run
    end
  end

  describe "cloud-init auth (optional, unlike vm bootstrap)" do
    it "succeeds with NO SSH credential at all (template-baked login is valid)" do
      expect { kpc.run }.not_to raise_error
    end

    it "plants a provided public key on the guest via cloud-init" do
      kpc.config[:ssh_public_key] = public_key_path

      expect(provisioner).to receive(:provision) do |spec|
        expect(spec[:config][:ssh_public_key]).to match(/\Assh-ed25519 /)
        Knife::Proxmox::Provisioner::Result.new(vmid: 9001, node: "pve1", ip: "10.0.10.50")
      end

      kpc.run
    end

    it "does NOT touch any bootstrap connection config" do
      kpc.config[:ssh_public_key] = public_key_path

      kpc.run

      expect(kpc.config[:connection_password]).to be_nil
      expect(kpc.config[:ssh_identity_file]).to be_nil
    end

    it "still rejects a PRIVATE key passed to --ssh-public-key" do
      private_key = Tempfile.new(["id_rsa", ""])
      private_key.write("-----BEGIN OPENSSH PRIVATE KEY-----\nABCDEF\n-----END OPENSSH PRIVATE KEY-----\n")
      private_key.flush
      kpc.config[:ssh_public_key] = private_key.path

      expect { kpc.run }.to raise_error(SystemExit)
      expect(kpc.ui).to have_received(:fatal!).with(/PRIVATE key/)
    end
  end
end
