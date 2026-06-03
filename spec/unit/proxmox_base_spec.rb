# frozen_string_literal: true

require "spec_helper"
require "chef/knife/helpers/proxmox_base"

RSpec.describe Chef::Knife::ProxmoxBase do
  # Throwaway command class that mixes in the helper, exactly as real commands do.
  # Chef::Knife#initialize derives the command name from the class name, which is nil for
  # an anonymous class — give it one so the instance constructs.
  let(:host_class) do
    Class.new(Chef::Knife) do
      include Chef::Knife::ProxmoxBase

      def self.snake_case_name
        "proxmox_test"
      end
    end
  end

  subject(:command) { host_class.new([]) }

  before do
    SharedConfig.install!
    # Treat fatal! as terminal so we can assert it instead of returning a value.
    allow(command.ui).to receive(:fatal!) { |msg| raise SystemExit, msg }
    # Silence informational/warning output unless an example asserts on it.
    allow(command.ui).to receive(:warn)
    allow(command.ui).to receive(:info)
  end

  # Isolate the process environment so global/per-cluster overrides do not leak between
  # examples or in from the developer's shell.
  around do |example|
    saved = ENV.to_hash
    ENV.delete_if { |key, _| key.start_with?("KNIFE_PROXMOX_TOKEN_SECRET") }
    example.run
  ensure
    ENV.replace(saved)
  end

  describe "option injection" do
    it "injects :proxmox_cluster into the including command's options" do
      expect(host_class.options).to include(:proxmox_cluster)
      expect(host_class.options[:proxmox_cluster][:long]).to eq("--proxmox-cluster NAME")
    end
  end

  describe "#proxmox_cluster_config" do
    it "resolves the cluster named by --proxmox-cluster" do
      command.config[:proxmox_cluster] = "lab"

      config = command.proxmox_cluster_config

      expect(config[:host]).to eq("pve-lab.test")
    end

    it "falls back to knife[:proxmox_default_cluster] when no flag is given" do
      config = command.proxmox_cluster_config

      expect(config[:host]).to eq("pve1.test")
    end

    it "returns a symbol-keyed hash" do
      expect(command.proxmox_cluster_config.keys).to all(be_a(Symbol))
    end

    it "memoizes the resolved config" do
      expect(command.proxmox_cluster_config).to be(command.proxmox_cluster_config)
    end

    it "fatals listing available keys when no cluster is selected" do
      Chef::Config[:knife].delete(:proxmox_default_cluster)

      expect { command.proxmox_cluster_config }.to raise_error(SystemExit)
      expect(command.ui).to have_received(:fatal!).with(/production.*lab|lab.*production/m)
    end

    it "fatals on an unknown cluster key" do
      command.config[:proxmox_cluster] = "does-not-exist"

      expect { command.proxmox_cluster_config }.to raise_error(SystemExit)
      expect(command.ui).to have_received(:fatal!).with(/unknown Proxmox cluster "does-not-exist"/)
    end
  end

  describe "token secret resolution precedence" do
    it "prefers the global ENV override over everything" do
      ENV["KNIFE_PROXMOX_TOKEN_SECRET"] = "global-secret"
      ENV["KNIFE_PROXMOX_TOKEN_SECRET_PRODUCTION"] = "per-cluster-secret"

      expect(command.proxmox_cluster_config[:token_secret]).to eq("global-secret")
    end

    it "prefers the per-cluster ENV override over the file value" do
      ENV["KNIFE_PROXMOX_TOKEN_SECRET_PRODUCTION"] = "per-cluster-secret"

      expect(command.proxmox_cluster_config[:token_secret]).to eq("per-cluster-secret")
    end

    it "normalizes non-alphanumeric chars in the per-cluster ENV var name" do
      Chef::Config[:knife][:proxmox_clusters] = {
        "pve-east.1" => { host: "h", token_id: "t", token_secret: "file-secret" },
      }
      command.config[:proxmox_cluster] = "pve-east.1"
      ENV["KNIFE_PROXMOX_TOKEN_SECRET_PVE_EAST_1"] = "env-secret"

      expect(command.proxmox_cluster_config[:token_secret]).to eq("env-secret")
    end

    it "uses the file value when no ENV override is present" do
      expect(command.proxmox_cluster_config[:token_secret])
        .to eq("00000000-1111-2222-3333-444444444444")
    end

    it "fatals when no secret resolves anywhere" do
      Chef::Config[:knife][:proxmox_clusters] = {
        "empty" => { host: "h", token_id: "t", token_secret: "" },
      }
      command.config[:proxmox_cluster] = "empty"

      expect { command.proxmox_cluster_config }.to raise_error(SystemExit)
      expect(command.ui).to have_received(:fatal!).with(/no Proxmox token secret/)
    end

    it "fatals when two cluster keys collide on the same per-cluster ENV var" do
      Chef::Config[:knife][:proxmox_clusters] = {
        "pve-east" => { host: "h1", token_id: "t1", token_secret: "s1" },
        "pve.east" => { host: "h2", token_id: "t2", token_secret: "s2" },
      }
      command.config[:proxmox_cluster] = "pve-east"

      expect { command.proxmox_cluster_config }.to raise_error(SystemExit)
      expect(command.ui).to have_received(:fatal!).with(/both map to ENV var/)
    end
  end

  describe "#proxmox_client" do
    it "builds a Knife::Proxmox::Client for the selected cluster" do
      command.config[:proxmox_cluster] = "production"

      expect(command.proxmox_client).to be_a(Knife::Proxmox::Client)
    end

    it "memoizes the client" do
      expect(command.proxmox_client).to be(command.proxmox_client)
    end

    it "warns on every run when verify_ssl is false" do
      command.config[:proxmox_cluster] = "lab"

      command.proxmox_client

      expect(command.ui).to have_received(:warn).with(/TLS.*DISABLED|verify_ssl: false/)
    end

    it "does not warn when verify_ssl is true" do
      command.config[:proxmox_cluster] = "production"

      command.proxmox_client

      expect(command.ui).not_to have_received(:warn)
    end

    it "treats an absent verify_ssl as true (no warning)" do
      Chef::Config[:knife][:proxmox_clusters] = {
        "noverify" => { host: "h", token_id: "t", token_secret: "s" },
      }
      command.config[:proxmox_cluster] = "noverify"

      command.proxmox_client

      expect(command.ui).not_to have_received(:warn)
    end

    it "passes resolved host, token and verify_ssl through to the Client" do
      command.config[:proxmox_cluster] = "lab"

      expect(Knife::Proxmox::Client).to receive(:new).with(
        host:         "pve-lab.test",
        token_id:     "knife@pve!lab",
        token_secret: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
        port:         8006,
        verify_ssl:   false
      ).and_call_original

      command.proxmox_client
    end

    it "defaults the port to 8006 when the cluster omits it" do
      command.config[:proxmox_cluster] = "lab"

      expect(Knife::Proxmox::Client).to receive(:new)
        .with(hash_including(port: 8006)).and_call_original

      command.proxmox_client
    end
  end

  describe "#proxmox_api" do
    it "wraps the client in a Knife::Proxmox::Api" do
      expect(command.proxmox_api).to be_a(Knife::Proxmox::Api)
    end

    it "memoizes the api" do
      expect(command.proxmox_api).to be(command.proxmox_api)
    end
  end

  describe "#msg_pair" do
    it "prints a colored label and the value" do
      allow(command.ui).to receive(:color).with("Node", :cyan).and_return("Node")

      command.msg_pair("Node", "pve1")

      expect(command.ui).to have_received(:info).with("Node: pve1")
    end

    it "accepts a custom color" do
      allow(command.ui).to receive(:color).with("VM ID", :green).and_return("VM ID")

      command.msg_pair("VM ID", 9001, :green)

      expect(command.ui).to have_received(:info).with("VM ID: 9001")
    end

    it "skips blank values" do
      command.msg_pair("Empty", "")
      command.msg_pair("Nil", nil)

      expect(command.ui).not_to have_received(:info)
    end
  end
end
