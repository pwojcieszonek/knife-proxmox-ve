# frozen_string_literal: true

require "spec_helper"
require "knife-proxmox-ve/client"
require "knife-proxmox-ve/errors"

RSpec.describe Knife::Proxmox::Client do
  let(:host) { "pve1.test" }
  let(:port) { 8006 }
  let(:token_id) { "knife@pve!automation" }
  let(:token_secret) { "00000000-1111-2222-3333-444444444444" }
  let(:base) { "https://#{host}:#{port}/api2/json" }
  let(:auth_header) { "PVEAPIToken=#{token_id}=#{token_secret}" }

  subject(:client) do
    described_class.new(host:, token_id:, token_secret:, port:)
  end

  describe ".encode_segment" do
    it "encodes a colon (UPID separator) as %3A" do
      expect(described_class.encode_segment("UPID:pve1:00001234")).to eq("UPID%3Apve1%3A00001234")
    end

    it "encodes a slash as %2F" do
      expect(described_class.encode_segment("local/template")).to eq("local%2Ftemplate")
    end

    it "coerces non-string values via to_s" do
      expect(described_class.encode_segment(9000)).to eq("9000")
    end
  end

  describe "#get" do
    it "hits the api2/json base with the Authorization PVEAPIToken header" do
      stub = stub_request(:get, "#{base}/version")
        .with(headers: { "Authorization" => auth_header, "Accept" => "application/json" })
        .to_return(status: 200, body: ProxmoxResponses.wrap("release" => "8.1"))

      client.get("/version")

      expect(stub).to have_been_requested
    end

    it "appends non-secret query params to the URL" do
      stub = stub_request(:get, "#{base}/cluster/resources")
        .with(query: { "type" => "vm" })
        .to_return(status: 200, body: ProxmoxResponses.cluster_resources)

      client.get("/cluster/resources", type: "vm")

      expect(stub).to have_been_requested
    end

    it "unwraps the JSON data envelope and returns the inner value" do
      stub_request(:get, "#{base}/cluster/nextid")
        .to_return(status: 200, body: ProxmoxResponses.next_id(9001))

      expect(client.get("/cluster/nextid")).to eq("9001")
    end

    it "returns an Array when data is an array" do
      stub_request(:get, "#{base}/cluster/resources")
        .with(query: { "type" => "vm" })
        .to_return(status: 200, body: ProxmoxResponses.cluster_resources)

      result = client.get("/cluster/resources", type: "vm")
      expect(result).to be_an(Array)
      expect(result.first["vmid"]).to eq(9000)
    end

    it "returns nil when the response body is empty" do
      stub_request(:get, "#{base}/ping").to_return(status: 200, body: "")
      expect(client.get("/ping")).to be_nil
    end
  end

  describe "#post" do
    it "form-encodes the body and unwraps data" do
      stub = stub_request(:post, "#{base}/nodes/pve1/qemu/9000/clone")
        .with(
          headers: { "Authorization" => auth_header },
          body: { "newid" => "9001", "name" => "web-02" }
        )
        .to_return(status: 200, body: ProxmoxResponses.wrap(ProxmoxResponses.upid))

      result = client.post("/nodes/pve1/qemu/9000/clone", newid: "9001", name: "web-02")

      expect(stub).to have_been_requested
      expect(result).to eq(ProxmoxResponses.upid)
    end

    it "sends a urlencoded content type" do
      stub = stub_request(:post, "#{base}/x")
        .with(headers: { "Content-Type" => "application/x-www-form-urlencoded" })
        .to_return(status: 200, body: ProxmoxResponses.wrap(nil))

      client.post("/x", a: "1")

      expect(stub).to have_been_requested
    end
  end

  describe "error mapping" do
    it "raises AuthError on 401 with a privilege-separation hint" do
      stub_request(:get, "#{base}/x").to_return(status: 401, body: ProxmoxResponses.wrap(nil))

      expect { client.get("/x") }.to raise_error(Knife::Proxmox::AuthError) do |err|
        expect(err.status).to eq(401)
        expect(err.message).to match(/privilege separation/)
      end
    end

    it "raises AuthError on 403" do
      stub_request(:get, "#{base}/x").to_return(status: 403, body: ProxmoxResponses.wrap(nil))

      expect { client.get("/x") }.to raise_error(Knife::Proxmox::AuthError) do |err|
        expect(err.status).to eq(403)
      end
    end

    it "raises NotFoundError on 404" do
      stub_request(:get, "#{base}/nodes/pve9/qemu/1").to_return(status: 404, body: "")

      expect { client.get("/nodes/pve9/qemu/1") }
        .to raise_error(Knife::Proxmox::NotFoundError) { |err| expect(err.status).to eq(404) }
    end

    it "raises ApiError(status: 500) on any other non-2xx" do
      stub_request(:get, "#{base}/x").to_return(status: 500, body: "boom")

      expect { client.get("/x") }.to raise_error(Knife::Proxmox::ApiError) do |err|
        expect(err.status).to eq(500)
        expect(err.body).to eq("boom")
      end
    end
  end

  describe "transport failures" do
    it "wraps a refused connection in ConnectionError" do
      stub_request(:get, "#{base}/x").to_raise(Errno::ECONNREFUSED)

      expect { client.get("/x") }.to raise_error(Knife::Proxmox::ConnectionError)
    end

    it "wraps a TLS verification failure in ConnectionError without leaking the token" do
      stub_request(:get, "#{base}/x").to_raise(OpenSSL::SSL::SSLError.new("verify failed"))

      expect { client.get("/x") }.to raise_error(Knife::Proxmox::ConnectionError) do |err|
        expect(err.message).not_to include(token_secret)
      end
    end
  end

  describe "TLS verification mode" do
    it "uses VERIFY_PEER by default" do
      fake_http = instance_double(Net::HTTP, request: response_ok)
      expect(fake_http).to receive(:use_ssl=).with(true)
      expect(fake_http).to receive(:verify_mode=).with(OpenSSL::SSL::VERIFY_PEER)
      allow(Net::HTTP).to receive(:new).with(host, port).and_return(fake_http)

      client.get("/version")
    end

    it "flips to VERIFY_NONE when verify_ssl: false" do
      insecure = described_class.new(
        host:, token_id:, token_secret:, port:, verify_ssl: false
      )
      fake_http = instance_double(Net::HTTP, request: response_ok)
      allow(fake_http).to receive(:use_ssl=)
      expect(fake_http).to receive(:verify_mode=).with(OpenSSL::SSL::VERIFY_NONE)
      allow(Net::HTTP).to receive(:new).with(host, port).and_return(fake_http)

      insecure.get("/version")
    end
  end

  describe "secret hygiene" do
    it "never sends the token secret in the request URI or query string" do
      stub_request(:get, "#{base}/x")
        .with(query: hash_including({}))
        .to_return(status: 200, body: ProxmoxResponses.wrap(nil))

      client.get("/x", foo: "bar")

      expect(
        a_request(:get, /#{Regexp.escape(token_secret)}/)
      ).not_to have_been_made
    end

    it "does not expose an echoed cipassword in a raised ApiError" do
      stub_request(:post, "#{base}/nodes/pve1/qemu/9000/config")
        .to_return(status: 400, body: "parameter verification failed: cipassword=hunter2&cores=2")

      expect { client.post("/nodes/pve1/qemu/9000/config", cipassword: "hunter2") }
        .to raise_error(Knife::Proxmox::ApiError) do |err|
          expect(err.body).not_to include("hunter2")
          expect(err.body).to include("[FILTERED]")
          expect(err.body).to include("cores=2")
        end
    end

    it "scrubs an echoed cipassword in a JSON error body" do
      stub_request(:post, "#{base}/x")
        .to_return(status: 400, body: JSON.generate("errors" => { "cipassword" => "hunter2" }))

      expect { client.post("/x", cipassword: "hunter2") }
        .to raise_error(Knife::Proxmox::ApiError) { |err| expect(err.body).not_to include("hunter2") }
    end

    it "redacts the token secret if Proxmox echoes it in an error body" do
      stub_request(:get, "#{base}/x")
        .to_return(status: 500, body: "internal: token #{token_secret} rejected")

      expect { client.get("/x") }.to raise_error(Knife::Proxmox::ApiError) do |err|
        expect(err.body).not_to include(token_secret)
      end
    end
  end

  def response_ok
    instance_double(Net::HTTPOK, code: "200", body: ProxmoxResponses.wrap(nil))
  end
end
