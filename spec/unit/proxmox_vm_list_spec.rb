# frozen_string_literal: true

require "spec_helper"
require "chef/knife/proxmox_vm_list"
require "knife-proxmox-ve/api"

RSpec.describe Chef::Knife::ProxmoxVmList do
  subject(:command) { described_class.new([]) }

  # Rows spanning two nodes, exactly as Api#list_resources returns them (symbol keys,
  # templates already excluded by the template: false filter).
  let(:rows) do
    [
      { vmid: 101, node: "pve1", name: "web-01", status: "running",
        template: 0, maxmem: 4_294_967_296, maxdisk: 10_737_418_240, uptime: 3600 },
      { vmid: 102, node: "pve2", name: "db-01", status: "stopped",
        template: 0, maxmem: 8_589_934_592, maxdisk: 21_474_836_480, uptime: 0 },
    ]
  end

  # The same rows after the table humanizer runs: bytes -> IEC sizes, seconds -> duration.
  let(:humanized_rows) do
    [
      { vmid: 101, node: "pve1", name: "web-01", status: "running",
        template: 0, maxmem: "4 GiB", maxdisk: "10 GiB", uptime: "1h" },
      { vmid: 102, node: "pve2", name: "db-01", status: "stopped",
        template: 0, maxmem: "8 GiB", maxdisk: "20 GiB", uptime: "0s" },
    ]
  end

  let(:api) { instance_double(Knife::Proxmox::Api) }

  before do
    SharedConfig.install!
    allow(command).to receive(:proxmox_api).and_return(api)
    allow(api).to receive(:list_resources).with(template: false).and_return(rows)
    # Capture rendered output instead of writing to the terminal.
    allow(command.ui).to receive(:output)
  end

  describe "#run" do
    it "requests only plain VMs (template: false), never templates" do
      command.run

      expect(api).to have_received(:list_resources).with(template: false)
    end

    it "renders every row with human-readable sizes and uptime when no node filter is given" do
      expect(command.ui).to receive(:output).with(humanized_rows)

      command.run
    end

    it "narrows rows client-side to the --node value" do
      command.config[:node] = "pve2"

      expect(command.ui).to receive(:output).with([humanized_rows[1]])

      command.run
    end

    it "keeps raw numeric sizes and uptime for json/yaml output (scripting)" do
      command.ui.config[:format] = "json"

      expect(command.ui).to receive(:output).with(rows)

      command.run
    end

    it "renders an empty list when --node matches no row" do
      command.config[:node] = "pve3"

      expect(command.ui).to receive(:output).with([])

      command.run
    end

    it "does not issue a per-node API call when filtering by node" do
      command.config[:node] = "pve1"

      command.run

      # Only the single template:false call; no second list_resources or node-scoped call.
      expect(api).to have_received(:list_resources).with(template: false).once
    end

    it "errors, shows usage and exits when given positional arguments" do
      command.name_args = ["extra"]
      allow(command.ui).to receive(:error)
      allow(command).to receive(:show_usage)

      expect { command.run }.to raise_error(SystemExit)
      expect(command.ui).to have_received(:error).with(/takes no arguments/)
      expect(command).to have_received(:show_usage)
    end
  end

  describe "command wiring" do
    it "declares the --node option" do
      expect(described_class.options).to include(:node)
      expect(described_class.options[:node][:long]).to eq("--node NODE")
    end

    it "mixes in Knife::ProxmoxBase via deps" do
      expect(described_class.ancestors).to include(Chef::Knife::ProxmoxBase)
    end

    it "sets the documented banner" do
      expect(described_class.banner).to eq("knife proxmox vm list (options)")
    end
  end
end
