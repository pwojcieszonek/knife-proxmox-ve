# frozen_string_literal: true

require "spec_helper"
require "chef/knife/proxmox_cluster_list"

RSpec.describe Chef::Knife::ProxmoxClusterList do
  subject(:command) { described_class.new([]) }

  # The raw secret values from SharedConfig — none of these may appear in any output.
  let(:production_secret) { "00000000-1111-2222-3333-444444444444" }
  let(:lab_secret) { "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" }

  # Capture what the command renders so we can inspect both the structured rows and the
  # final formatted string handed to ui.output.
  let(:captured) { [] }

  before do
    SharedConfig.install!
    allow(command.ui).to receive(:output) { |obj| captured << obj }
    allow(command.ui).to receive(:warn)
    allow(command.ui).to receive(:error)
    allow(command.ui).to receive(:fatal!) { |msg| raise SystemExit, msg }
  end

  # Isolate the process environment so secret overrides do not leak between examples or
  # in from the developer's shell.
  around do |example|
    saved = ENV.to_hash
    ENV.delete_if { |key, _| key.start_with?("KNIFE_PROXMOX_TOKEN_SECRET") }
    example.run
  ensure
    ENV.replace(saved)
  end

  def rows
    captured.first
  end

  def row_for(key)
    rows.find { |r| r["cluster"].start_with?(key.to_s) }
  end

  describe "#run" do
    it "lists every configured cluster" do
      command.run

      expect(rows.length).to eq(2)
      expect(rows.map { |r| r["cluster"].sub(/ \*\z/, "") }).to contain_exactly("production", "lab")
    end

    it "reports host, port and token_id per cluster" do
      command.run

      production = row_for("production")
      expect(production["host"]).to eq("pve1.test")
      expect(production["port"]).to eq(8006)
      expect(production["token_id"]).to eq("knife@pve!automation")
    end

    it "defaults the port to 8006 when the cluster omits it" do
      command.run

      expect(row_for("lab")["port"]).to eq(8006)
    end

    it "marks the default cluster" do
      command.run

      expect(row_for("production")["default"]).to be(true)
      expect(row_for("lab")["default"]).to be(false)
      expect(row_for("production")["cluster"]).to include("*")
    end

    it "reports verify_ssl per cluster, treating an absent value as true" do
      Chef::Config[:knife][:proxmox_clusters] = {
        "production" => SharedConfig.clusters["production"],
        "lab"      => SharedConfig.clusters["lab"],
        "noverify" => { host: "h", token_id: "t", token_secret: "s" },
      }

      command.run

      expect(row_for("production")["verify_ssl"]).to be(true)
      expect(row_for("lab")["verify_ssl"]).to be(false)
      expect(row_for("noverify")["verify_ssl"]).to be(true)
    end

    it "rejects positional arguments" do
      command.name_args = ["extra"]

      expect { command.run }.to raise_error(SystemExit)
      expect(command.ui).to have_received(:error).with(/takes no arguments/)
    end

    it "warns and renders nothing when no clusters are configured" do
      Chef::Config[:knife][:proxmox_clusters] = {}

      command.run

      expect(command.ui).to have_received(:warn).with(/no Proxmox clusters configured/)
      expect(captured).to be_empty
    end
  end

  describe "secret resolution reporting" do
    it "reports secret_resolves true when the config file carries a secret" do
      command.run

      expect(row_for("production")["secret_resolves"]).to be(true)
      expect(row_for("lab")["secret_resolves"]).to be(true)
    end

    it "reports secret_resolves false when no secret resolves anywhere" do
      Chef::Config[:knife][:proxmox_clusters] = {
        "empty" => { host: "h", token_id: "t", token_secret: "" },
      }

      command.run

      expect(row_for("empty")["secret_resolves"]).to be(false)
    end

    it "reports secret_resolves true when only the global ENV override is set" do
      Chef::Config[:knife][:proxmox_clusters] = {
        "empty" => { host: "h", token_id: "t", token_secret: "" },
      }
      ENV["KNIFE_PROXMOX_TOKEN_SECRET"] = "global-secret"

      command.run

      expect(row_for("empty")["secret_resolves"]).to be(true)
    end

    it "reports secret_resolves true when only the per-cluster ENV override is set" do
      Chef::Config[:knife][:proxmox_clusters] = {
        "empty" => { host: "h", token_id: "t", token_secret: "" },
      }
      ENV["KNIFE_PROXMOX_TOKEN_SECRET_EMPTY"] = "per-cluster-secret"

      command.run

      expect(row_for("empty")["secret_resolves"]).to be(true)
    end

    it "never includes secret_resolves as a key carrying the secret value" do
      command.run

      expect(rows.first.keys).to include("secret_resolves")
      expect(rows.flat_map(&:values)).not_to include(production_secret, lab_secret)
    end
  end

  describe "secret never leaks across output formats" do
    # The command renders structured rows via ui.output(format_for_display(...)); knife's
    # ui serializes those rows per --format. Assert the secret is absent from the actual
    # serialized text for every supported format.
    %w{summary text json yaml pp}.each do |format|
      it "does not print the raw secret under --format #{format}" do
        command.config[:format] = format

        command.run

        # Format-agnostic check: no captured object stringifies to the secret under any
        # serializer knife could pick.
        rendered = captured.map { |obj| dump_all_formats(obj) }.join("\n")

        expect(rendered).not_to include(production_secret)
        expect(rendered).not_to include(lab_secret)
      end
    end
  end

  # Stringify an object through every serializer a knife --format could use, so the leak
  # assertion holds no matter which formatter knife picks at print time.
  def dump_all_formats(obj)
    require "json"
    require "yaml"
    [obj.inspect, obj.to_s, JSON.generate(obj), YAML.dump(obj)].join("\n")
  end
end
