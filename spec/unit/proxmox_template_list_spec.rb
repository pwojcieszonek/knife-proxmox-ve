# frozen_string_literal: true

require "spec_helper"
require "chef/knife/proxmox_template_list"
require "knife-proxmox-ve/api"

RSpec.describe Chef::Knife::ProxmoxTemplateList do
  subject(:command) { described_class.new([]) }

  # Verifying double: a typo in :list_resources would fail here, guarding the Api contract.
  let(:api) { instance_double(Knife::Proxmox::Api) }

  # The Api normalizes each /cluster/resources entry into this symbol-keyed shape.
  let(:template_rows) do
    [
      {
        vmid:     9000,
        node:     "pve1",
        name:     "ubuntu-2404-template",
        status:   "stopped",
        template: 1,
        maxmem:   2_147_483_648,
        maxdisk:  10_737_418_240,
        uptime:   nil,
      },
    ]
  end

  before do
    allow(command).to receive(:proxmox_api).and_return(api)
    allow(command.ui).to receive(:output)
    allow(command.ui).to receive(:error)
  end

  describe "#run" do
    it "asks the api for templates only" do
      allow(api).to receive(:list_resources).with(template: true).and_return(template_rows)

      command.run

      expect(api).to have_received(:list_resources).with(template: true)
    end

    it "renders the template rows with human-readable sizes through the knife display pipeline" do
      allow(api).to receive(:list_resources).with(template: true).and_return(template_rows)

      command.run

      expect(command.ui).to have_received(:output) do |displayed|
        row = displayed.first
        expect(row).to include(
          name:    "ubuntu-2404-template",
          vmid:    9000,
          node:    "pve1",
          maxdisk: "10 GiB",
          maxmem:  "2 GiB"
        )
      end
    end

    it "keeps raw numeric sizes for json/yaml output (scripting)" do
      command.ui.config[:format] = "json"
      allow(api).to receive(:list_resources).with(template: true).and_return(template_rows)

      command.run

      expect(command.ui).to have_received(:output) do |displayed|
        row = displayed.first
        expect(row).to include(maxdisk: 10_737_418_240, maxmem: 2_147_483_648)
      end
    end

    it "presents one row per template" do
      allow(api).to receive(:list_resources).with(template: true).and_return(template_rows)

      command.run

      expect(command.ui).to have_received(:output) do |displayed|
        expect(displayed.length).to eq(1)
      end
    end

    it "renders an empty result without error" do
      allow(api).to receive(:list_resources).with(template: true).and_return([])

      command.run

      expect(command.ui).to have_received(:output).with([])
    end

    context "when extra arguments are passed" do
      subject(:command) { described_class.new(["unexpected"]) }

      before do
        allow(command).to receive(:show_usage)
        allow(command).to receive(:exit).and_raise(SystemExit)
      end

      it "errors, shows usage and exits non-zero" do
        expect { command.run }.to raise_error(SystemExit)

        expect(command.ui).to have_received(:error).with(/takes no arguments/)
        expect(command).to have_received(:show_usage)
        expect(command).to have_received(:exit).with(1)
      end

      it "never queries the api" do
        allow(api).to receive(:list_resources)

        begin
          command.run
        rescue SystemExit
          # expected
        end

        expect(api).not_to have_received(:list_resources)
      end
    end
  end

  describe "command registration" do
    it "carries the documented banner" do
      expect(described_class.banner).to eq("knife proxmox template list (options)")
    end

    it "mixes in the shared Proxmox base helper" do
      expect(described_class.ancestors).to include(Chef::Knife::ProxmoxBase)
    end
  end
end
