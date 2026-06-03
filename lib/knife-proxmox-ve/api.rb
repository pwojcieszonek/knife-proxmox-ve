# frozen_string_literal: true

require "knife-proxmox-ve/client"
require "knife-proxmox-ve/errors"

module Knife
  module Proxmox
    # Stateless map of the verified Proxmox VE endpoints onto a Knife::Proxmox::Client.
    # Every method is a single round-trip with no cross-call sequencing (that lives in the
    # Provisioner). It knows the shape of each endpoint's payload, applies the qemu filter
    # where the cluster API mixes VM types, and keeps path segments injection-safe by
    # routing node names and UPIDs through Client.encode_segment.
    class Api
      # Polling defaults for #wait_task. A monotonic deadline (not wall clock) guards the
      # timeout so a clock step cannot stretch or cut short the wait.
      DEFAULT_TIMEOUT = 300
      DEFAULT_INTERVAL = 2

      def initialize(client)
        @client = client
      end

      # Resolve a template by name or numeric vmid. Filters /cluster/resources down to qemu
      # templates and matches either the name or the vmid. Raises NotFoundError if no
      # template matches, so the caller never proceeds with a phantom source.
      def find_template(name_or_vmid)
        wanted = name_or_vmid.to_s
        entry = qemu_resources.find do |r|
          r["template"].to_i == 1 &&
            (r["name"].to_s == wanted || r["vmid"].to_s == wanted)
        end

        unless entry
          raise NotFoundError.new(
            "no qemu template matches #{name_or_vmid.inspect}", status: 404
          )
        end

        { vmid: entry["vmid"], node: entry["node"], name: entry["name"] }
      end

      # List qemu resources, optionally narrowed to templates (template: true) or plain VMs
      # (template: false); nil keeps both. Returns a uniform Hash per entry with missing
      # fields normalized to nil.
      def list_resources(template: nil)
        qemu_resources.select { |r| matches_template?(r, template) }.map do |r|
          {
            vmid:     r["vmid"],
            node:     r["node"],
            name:     r["name"],
            status:   r["status"],
            template: r["template"],
            maxmem:   r["maxmem"],
            maxdisk:  r["maxdisk"],
            uptime:   r["uptime"],
          }
        end
      end

      # The cluster's next free VMID. Proxmox returns it as a string; coerce to Integer.
      def next_id
        @client.get("/cluster/nextid").to_i
      end

      # Clone a template into a new VM. Returns the UPID of the async clone task.
      def clone(node:, vmid:, newid:, **params)
        @client.post(
          "/nodes/#{enc(node)}/qemu/#{enc(vmid)}/clone",
          { newid: }.merge(params)
        )
      end

      # Apply VM config (cores, memory, net0, cloud-init keys, ...). Only the supplied keys
      # are sent, so a partial update never clears unrelated config.
      def update_config(node:, vmid:, **params)
        @client.post("/nodes/#{enc(node)}/qemu/#{enc(vmid)}/config", params)
      end

      # Start a VM. Returns the UPID of the async start task.
      def start(node:, vmid:)
        @client.post("/nodes/#{enc(node)}/qemu/#{enc(vmid)}/status/start")
      end

      # Current VM config Hash (string keys). Used to detect the cloud-init drive and to
      # read back a static IP after configuration.
      def vm_config(node:, vmid:)
        @client.get("/nodes/#{enc(node)}/qemu/#{enc(vmid)}/config")
      end

      # Routable IPs reported by the guest agent, IPv4 first. Skips loopback (lo / 127.*)
      # and IPv6 link-local (fe80::). Raises (NotFoundError/ApiError) when the agent is not
      # available rather than returning an empty result that the caller would misread.
      def agent_ip_addresses(node:, vmid:)
        result = @client.get(
          "/nodes/#{enc(node)}/qemu/#{enc(vmid)}/agent/network-get-interfaces"
        )
        interfaces = (result && result["result"]) || []

        addresses = interfaces.reject { |iface| iface["name"] == "lo" }.flat_map do |iface|
          (iface["ip-addresses"] || []).map { |a| a["ip-address"] }
        end

        addresses.compact.reject { |ip| routable_skip?(ip) }.sort_by { |ip| ipv4?(ip) ? 0 : 1 }
      end

      # Poll a task to completion. The node is parsed from the UPID itself (UPID:<node>:...)
      # so the caller cannot pass a mismatched node. Returns true on exitstatus "OK";
      # raises TaskError (with a scrubbed log) on any other exitstatus; raises TimeoutError
      # once the monotonic deadline passes.
      def wait_task(upid:, timeout: DEFAULT_TIMEOUT, interval: DEFAULT_INTERVAL, sleeper: nil)
        node = node_from_upid(upid)
        sleeper ||= ->(seconds) { sleep(seconds) }
        deadline = monotonic_now + timeout

        loop do
          status = task_status(node, upid)
          if status["status"] == "stopped"
            return true if status["exitstatus"] == "OK"

            raise_task_error(node, upid, status["exitstatus"])
          end

          raise TimeoutError, "task #{upid} did not finish within #{timeout}s" if monotonic_now >= deadline

          sleeper.call(interval)
        end
      end

      private

      def enc(value)
        Client.encode_segment(value)
      end

      def qemu_resources
        (@client.get("/cluster/resources", type: "vm") || []).select { |r| r["type"] == "qemu" }
      end

      def matches_template?(resource, template)
        return true if template.nil?

        resource["template"].to_i == (template ? 1 : 0)
      end

      def task_status(node, upid)
        @client.get("/nodes/#{enc(node)}/tasks/#{enc(upid)}/status")
      end

      def raise_task_error(node, upid, exitstatus)
        log = task_log(node, upid)
        raise TaskError.new(
          "task #{upid} failed: #{exitstatus}", upid:, exitstatus:, log:
        )
      end

      # The task log endpoint returns an array of { "n" => line_no, "t" => text } entries.
      # It is an HTTP 200 body (so the Client does NOT scrub it), and Proxmox task logs echo
      # the applied params — including cipassword/sshkeys — so scrub the joined text before it
      # reaches TaskError#log and the terminal.
      def task_log(node, upid)
        entries = @client.get("/nodes/#{enc(node)}/tasks/#{enc(upid)}/log") || []
        @client.scrub_text(entries.map { |entry| entry["t"] }.compact.join("\n"))
      end

      # UPID shape: UPID:<node>:<pid>:<pstart>:<starttime>:<type>:<id>:<user>:
      def node_from_upid(upid)
        node = upid.to_s.split(":")[1]
        if node.nil? || node.empty?
          raise TaskError.new(
            "cannot parse node from UPID #{upid.inspect}", upid:, exitstatus: nil
          )
        end

        node
      end

      def routable_skip?(ip)
        ip.start_with?("127.") || ip.start_with?("fe80:") || ip == "::1"
      end

      def ipv4?(ip)
        ip.include?(".") && !ip.include?(":")
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
