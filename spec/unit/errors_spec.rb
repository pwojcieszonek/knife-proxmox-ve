# frozen_string_literal: true

require "spec_helper"
require "knife-proxmox-ve/errors"

RSpec.describe Knife::Proxmox do
  describe "error hierarchy" do
    it "roots every error at Knife::Proxmox::Error < StandardError" do
      expect(described_class::Error.ancestors).to include(StandardError)
      [described_class::ConnectionError, described_class::ApiError,
       described_class::TaskError, described_class::TimeoutError].each do |klass|
         expect(klass.ancestors).to include(described_class::Error)
       end
    end

    it "treats AuthError and NotFoundError as ApiError subclasses" do
      expect(described_class::AuthError.ancestors).to include(described_class::ApiError)
      expect(described_class::NotFoundError.ancestors).to include(described_class::ApiError)
    end
  end

  describe described_class::ApiError do
    it "carries status and body" do
      err = described_class.new("boom", status: 500, body: "oops")
      expect(err.message).to eq("boom")
      expect(err.status).to eq(500)
      expect(err.body).to eq("oops")
    end
  end

  describe described_class::TaskError do
    it "carries upid, exitstatus and log" do
      err = described_class.new("task failed", upid: "UPID:pve1:x", exitstatus: "boom", log: "trace")
      expect(err.upid).to eq("UPID:pve1:x")
      expect(err.exitstatus).to eq("boom")
      expect(err.log).to eq("trace")
    end
  end
end
