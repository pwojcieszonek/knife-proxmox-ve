# frozen_string_literal: true

require "spec_helper"
require "tempfile"
require "tmpdir"
require "chef/knife/bootstrap"
require "knife-proxmox-ve/api"
require "knife-proxmox-ve/provisioner"
require "chef/knife/proxmox_vm_bootstrap"

RSpec.describe Chef::Knife::ProxmoxVmBootstrap do
  subject(:kpc) { described_class.new }

  let(:api) { instance_double(Knife::Proxmox::Api) }
  let(:provisioner) do
    instance_double(
      Knife::Proxmox::Provisioner,
      provision: Knife::Proxmox::Provisioner::Result.new(vmid: 9001, node: "pve1", ip: "10.0.10.50")
    )
  end

  # A real, readable public-key file on disk so resolve_ssh_public_key passes.
  let(:public_key_path) do
    file = Tempfile.new(["id_ed25519", ".pub"])
    file.write("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA test@host\n")
    file.flush
    file.path
  end

  before do
    SharedConfig.install!

    # fatal! must be terminal so we can assert it raises instead of returning.
    allow(kpc.ui).to receive(:fatal!) { |msg| raise SystemExit, msg }
    allow(kpc.ui).to receive(:info)
    allow(kpc.ui).to receive(:warn)
    allow(kpc.ui).to receive(:color) { |text, _| text }

    # Nothing in these specs may touch the network or a real Proxmox.
    allow(kpc).to receive(:proxmox_api).and_return(api)
    allow(api).to receive(:find_template)
      .and_return(vmid: 9000, node: "pve1", name: "ubuntu-2404-template")
    allow(Knife::Proxmox::Provisioner).to receive(:new).and_return(provisioner)

    kpc.name_args = ["web-01"]
    kpc.config[:template] = "ubuntu-2404-template"
    kpc.config[:ssh_public_key] = public_key_path
  end

  describe "command wiring" do
    it "subclasses Bootstrap (inherits the post-provision lifecycle)" do
      expect(described_class.ancestors).to include(Chef::Knife::Bootstrap)
    end

    it "mixes in the shared Proxmox base helper" do
      expect(described_class.ancestors).to include(Chef::Knife::ProxmoxBase)
    end

    it "mixes in the shared provisioning concern" do
      expect(described_class.ancestors).to include(Chef::Knife::ProxmoxVmProvision)
    end

    it "declares the new --template option without redeclaring inherited bootstrap options" do
      expect(described_class.options).to include(:template, :newid, :linked_clone, :cipassword)
      # Connection options are inherited, not redeclared by this command.
      expect(described_class.options[:connection_protocol]).not_to be_nil
    end

    it "sets a NAME banner" do
      expect(described_class.banner).to match(/vm bootstrap NAME/)
    end

    it "does not override the inherited #run" do
      expect(described_class.instance_method(:run).owner).to eq(Chef::Knife::Bootstrap)
    end
  end

  describe "#plugin_setup!" do
    it "defaults ssh_verify_host_key to :accept_new (TOFU for a brand-new VM)" do
      kpc.plugin_setup!

      expect(kpc.config[:ssh_verify_host_key]).to eq(:accept_new)
    end

    it "defaults the connection to ssh on port 22" do
      kpc.plugin_setup!

      expect(kpc.config[:connection_protocol]).to eq("ssh")
      expect(kpc.config[:connection_port]).to eq(22)
    end

    it "does not clobber an explicit verify-host-key choice" do
      kpc.config[:ssh_verify_host_key] = :always

      kpc.plugin_setup!

      expect(kpc.config[:ssh_verify_host_key]).to eq(:always)
    end

    it "waits for cloud-init to finish before the bootstrap installs the client" do
      kpc.plugin_setup!

      expect(kpc.config[:bootstrap_preinstall_command]).to match(/cloud-init status --wait/)
    end

    it "does not override an explicit --bootstrap-preinstall-command" do
      kpc.config[:bootstrap_preinstall_command] = "echo custom-preinstall"

      kpc.plugin_setup!

      expect(kpc.config[:bootstrap_preinstall_command]).to eq("echo custom-preinstall")
    end
  end

  # The CINC default is applied from #plugin_setup! (the first hook Bootstrap#run invokes),
  # so it is asserted both there and directly against the helper it delegates to.
  describe "bootstrap product (CINC by default)" do
    def apply! = kpc.send(:default_bootstrap_to_cinc!)

    it "pins the bootstrap install to the CINC omnitruck by default" do
      apply!

      expect(kpc.config[:bootstrap_product]).to eq("cinc")
      expect(kpc.config[:bootstrap_url]).to eq("https://omnitruck.cinc.sh/install.sh")
    end

    it "is applied from #plugin_setup! (the first hook Bootstrap#run invokes)" do
      kpc.plugin_setup!

      expect(kpc.config[:bootstrap_product]).to eq("cinc")
      expect(kpc.config[:bootstrap_url]).to eq("https://omnitruck.cinc.sh/install.sh")
    end

    it "keeps knife's own (Chef) defaults when config.rb opts into chef" do
      Chef::Config[:knife][:proxmox_bootstrap_product] = "chef"

      apply!

      expect(kpc.config[:bootstrap_product]).to be_nil
      expect(kpc.config[:bootstrap_url]).to be_nil
    end

    it "still applies the CINC defaults when config.rb explicitly asks for cinc" do
      Chef::Config[:knife][:proxmox_bootstrap_product] = "CINC"

      apply!

      expect(kpc.config[:bootstrap_product]).to eq("cinc")
      expect(kpc.config[:bootstrap_url]).to eq("https://omnitruck.cinc.sh/install.sh")
    end

    it "respects an explicit --bootstrap-product without forcing the CINC url" do
      kpc.config[:bootstrap_product] = "chef-ice"

      apply!

      expect(kpc.config[:bootstrap_product]).to eq("chef-ice")
      expect(kpc.config[:bootstrap_url]).to be_nil
    end

    it "yields to a custom --bootstrap-install-command" do
      kpc.config[:bootstrap_install_command] = "apt-get install -y cinc"

      apply!

      expect(kpc.config[:bootstrap_product]).to be_nil
      expect(kpc.config[:bootstrap_url]).to be_nil
    end
  end

  describe "#validate_name_args!" do
    it "is a no-op and does NOT raise on empty name_args" do
      kpc.name_args = []

      expect { kpc.validate_name_args! }.not_to raise_error
    end
  end

  describe "#plugin_validate_options!" do
    before { kpc.plugin_setup! }

    it "passes for a valid name + template + public key" do
      expect { kpc.plugin_validate_options! }.not_to raise_error
    end

    it "fatals when the VM name is missing" do
      kpc.name_args = []

      expect { kpc.plugin_validate_options! }.to raise_error(SystemExit)
      expect(kpc.ui).to have_received(:fatal!).with(/VM NAME/)
    end

    it "fatals when --template is missing" do
      kpc.config[:template] = nil

      expect { kpc.plugin_validate_options! }.to raise_error(SystemExit)
      expect(kpc.ui).to have_received(:fatal!).with(/template/)
    end

    it "fatals when a PRIVATE key file is supplied to --ssh-public-key" do
      private_key = Tempfile.new(["id_rsa", ""])
      private_key.write("-----BEGIN OPENSSH PRIVATE KEY-----\nABCDEF\n-----END OPENSSH PRIVATE KEY-----\n")
      private_key.flush
      kpc.config[:ssh_public_key] = private_key.path

      expect { kpc.plugin_validate_options! }.to raise_error(SystemExit)
      expect(kpc.ui).to have_received(:fatal!).with(/PRIVATE key/)
    end

    it "fatals when --ssh-public-key points at an unreadable path" do
      kpc.config[:ssh_public_key] = "/no/such/key.pub"

      expect { kpc.plugin_validate_options! }.to raise_error(SystemExit)
      expect(kpc.ui).to have_received(:fatal!).with(/not readable/)
    end

    it "fatals when no SSH key and no password are available" do
      kpc.config[:ssh_public_key] = nil

      expect { kpc.plugin_validate_options! }.to raise_error(SystemExit)
      expect(kpc.ui).to have_received(:fatal!).with(/no SSH credential/)
    end

    it "accepts a cloud-init password from ENV instead of a key" do
      kpc.config[:ssh_public_key] = nil

      with_env(described_class::ENV_CIPASSWORD => "s3cret") do
        expect { kpc.plugin_validate_options! }.not_to raise_error
      end
    end

    it "accepts the cluster's default :ssh_public_key when --ssh-public-key is omitted" do
      kpc.config[:ssh_public_key] = nil
      Chef::Config[:knife][:proxmox_clusters]["production"][:ssh_public_key] = public_key_path

      expect { kpc.plugin_validate_options! }.not_to raise_error
    end

    it "prompts (no echo) for the password when --cipassword is set" do
      kpc.config[:ssh_public_key] = nil
      kpc.config[:cipassword] = true
      allow(kpc.ui).to receive(:ask).with(anything, echo: false).and_return("typed-secret")

      expect { kpc.plugin_validate_options! }.not_to raise_error
      expect(kpc.ui).to have_received(:ask).with(anything, echo: false)
    end

    describe "scalar validation" do
      it "fatals when --cores is not a positive integer" do
        kpc.config[:cores] = "0"

        expect { kpc.plugin_validate_options! }.to raise_error(SystemExit)
        expect(kpc.ui).to have_received(:fatal!).with(/greater than 0/)
      end

      it "fatals when --memory is not an integer" do
        kpc.config[:memory] = "lots"

        expect { kpc.plugin_validate_options! }.to raise_error(SystemExit)
        expect(kpc.ui).to have_received(:fatal!).with(/integer/)
      end

      it "fatals on a malformed --bridge" do
        # Arbitrary interface names are accepted now (e.g. eth0, SDN VNets); only the kernel's
        # own constraints are enforced — here a "/" makes it an invalid interface name.
        kpc.config[:bridge] = "vm/br0"

        expect { kpc.plugin_validate_options! }.to raise_error(SystemExit)
        expect(kpc.ui).to have_received(:fatal!).with(/bridge/)
      end

      it "fatals on a non-IP --ip that is not 'dhcp'" do
        kpc.config[:ip] = "not-an-ip"

        expect { kpc.plugin_validate_options! }.to raise_error(SystemExit)
        expect(kpc.ui).to have_received(:fatal!).with(/valid IPv4/)
      end

      it "accepts ip=dhcp" do
        kpc.config[:ip] = "dhcp"

        expect { kpc.plugin_validate_options! }.not_to raise_error
      end

      it "accepts a CIDR --ip" do
        kpc.config[:ip] = "10.0.10.50/24"

        expect { kpc.plugin_validate_options! }.not_to raise_error
      end

      it "fatals on a non-IPv4 --ip (IPv6), since ipconfig0/gateway are IPv4-only here" do
        kpc.config[:ip] = "2001:db8::5"

        expect { kpc.plugin_validate_options! }.to raise_error(SystemExit)
        expect(kpc.ui).to have_received(:fatal!).with(/IPv4/)
      end

      it "fatals on a non-IPv4 --gateway" do
        kpc.config[:gateway] = "::1"

        expect { kpc.plugin_validate_options! }.to raise_error(SystemExit)
        expect(kpc.ui).to have_received(:fatal!).with(/gateway/)
      end
    end
  end

  describe "#plugin_create_instance!" do
    before do
      kpc.plugin_setup!
      kpc.plugin_validate_options!
    end

    it "injects the resolved VM IP into @name_args for the bootstrap to connect to" do
      kpc.plugin_create_instance!

      expect(kpc.name_args).to eq(["10.0.10.50"])
    end

    it "defaults the chef node name to the VM name" do
      kpc.plugin_create_instance!

      expect(kpc.config[:chef_node_name]).to eq("web-01")
    end

    it "does not override an explicit -N node name" do
      kpc.config[:chef_node_name] = "explicit-node"

      kpc.plugin_create_instance!

      expect(kpc.config[:chef_node_name]).to eq("explicit-node")
    end

    it "drives the provisioner with the resolved template and cluster-default storage/bridge" do
      expect(Knife::Proxmox::Provisioner).to receive(:new).with(api, ui: kpc.ui).and_return(provisioner)
      expect(provisioner).to receive(:provision) do |spec|
        expect(spec[:name]).to eq("web-01")
        expect(spec[:template]).to eq(vmid: 9000, node: "pve1", name: "ubuntu-2404-template")
        # production cluster defaults flow in when the CLI omits them.
        expect(spec[:storage]).to eq("local-lvm")
        expect(spec[:config][:bridge]).to eq("vmbr0")
        expect(spec[:config][:ciuser]).to eq("ubuntu")
        expect(spec[:config][:ssh_public_key]).to match(/\Assh-ed25519 /)
        # Bootstrap must connect, so it waits for SSH and treats a missing IP as fatal.
        expect(spec[:wait_for_ssh]).to be(true)
        expect(spec[:require_ip]).to be(true)
        Knife::Proxmox::Provisioner::Result.new(vmid: 9001, node: "pve1", ip: "10.0.10.50")
      end

      kpc.plugin_create_instance!
    end

    it "prefers an explicit --storage over the cluster default" do
      kpc.config[:storage] = "fast-nvme"

      expect(provisioner).to receive(:provision) do |spec|
        expect(spec[:storage]).to eq("fast-nvme")
        Knife::Proxmox::Provisioner::Result.new(vmid: 9001, node: "pve1", ip: "10.0.10.50")
      end

      kpc.plugin_create_instance!
    end

    it "clones full by default (full=true, storage carried through)" do
      expect(provisioner).to receive(:provision) do |spec|
        expect(spec[:full]).to be(true)
        expect(spec[:storage]).to eq("local-lvm")
        Knife::Proxmox::Provisioner::Result.new(vmid: 9001, node: "pve1", ip: "10.0.10.50")
      end

      kpc.plugin_create_instance!
    end

    it "does a linked clone with --linked-clone and drops storage (Proxmox rejects it)" do
      kpc.config[:linked_clone] = true

      expect(provisioner).to receive(:provision) do |spec|
        expect(spec[:full]).to be(false)
        expect(spec[:storage]).to be_nil
        Knife::Proxmox::Provisioner::Result.new(vmid: 9001, node: "pve1", ip: "10.0.10.50")
      end

      kpc.plugin_create_instance!
    end

    it "warns that --storage is ignored when combined with --linked-clone" do
      kpc.config[:linked_clone] = true
      kpc.config[:storage] = "fast-nvme"

      kpc.plugin_create_instance!

      expect(kpc.ui).to have_received(:warn).with(/--storage is ignored/)
    end

    it "sets ssh_identity_file from the .pub path when the private key exists" do
      dir = Dir.mktmpdir
      private_key = File.join(dir, "id_ed25519")
      File.write(private_key, "PRIVATE")
      File.write("#{private_key}.pub", "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA test@host\n")
      kpc.config[:ssh_public_key] = "#{private_key}.pub"
      kpc.plugin_validate_options!

      kpc.plugin_create_instance!

      expect(kpc.config[:ssh_identity_file]).to eq(private_key)
    end

    it "defaults the bootstrap connection user to the cluster's :ciuser" do
      kpc.plugin_create_instance!

      expect(kpc.config[:connection_user]).to eq("ubuntu")
    end

    it "does not override an explicit --connection-user" do
      kpc.config[:connection_user] = "admin"

      kpc.plugin_create_instance!

      expect(kpc.config[:connection_user]).to eq("admin")
    end

    it "plants the cluster's default :ssh_public_key on the guest when --ssh-public-key is omitted" do
      kpc.config[:ssh_public_key] = nil
      Chef::Config[:knife][:proxmox_clusters]["production"][:ssh_public_key] = public_key_path
      # The shared before already memoized the cluster config; drop it so the new default is read.
      kpc.instance_variable_set(:@proxmox_cluster_config, nil)
      kpc.plugin_validate_options!

      expect(provisioner).to receive(:provision) do |spec|
        expect(spec[:config][:ssh_public_key]).to match(/\Assh-ed25519 /)
        Knife::Proxmox::Provisioner::Result.new(vmid: 9001, node: "pve1", ip: "10.0.10.50")
      end

      kpc.plugin_create_instance!
    end
  end

  describe "#plugin_finalize" do
    before do
      kpc.plugin_setup!
      kpc.plugin_validate_options!
      kpc.plugin_create_instance!
    end

    it "prints a summary of the provisioned VM" do
      kpc.plugin_finalize

      expect(kpc.ui).to have_received(:info).with(/VM name: web-01/)
      expect(kpc.ui).to have_received(:info).with(/VMID: 9001/)
      expect(kpc.ui).to have_received(:info).with(/Node: pve1/)
      expect(kpc.ui).to have_received(:info).with(/IP: 10\.0\.10\.50/)
    end
  end

  # Run a block with ENV temporarily set, restoring the prior environment after.
  def with_env(overrides)
    saved = ENV.to_hash
    overrides.each { |key, value| ENV[key] = value }
    yield
  ensure
    ENV.replace(saved)
  end
end
