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
      # Polling defaults for #wait_task and #wait_status. A monotonic deadline (not wall
      # clock) guards the timeout so a clock step cannot stretch or cut short the wait.
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

      # Resolve a plain VM (never a template) by name or numeric vmid. A vmid is unique
      # cluster-wide, but names are not — an ambiguous name raises AmbiguousMatchError
      # instead of picking an arbitrary VM to act on. Raises NotFoundError when nothing
      # matches. Returns identity plus the cluster-cached status (see #vm_status for the
      # live one).
      def find_vm(name_or_vmid)
        wanted = name_or_vmid.to_s
        matches = qemu_resources.select do |r|
          r["template"].to_i != 1 &&
            (r["name"].to_s == wanted || r["vmid"].to_s == wanted)
        end

        if matches.empty?
          raise NotFoundError.new("no qemu VM matches #{name_or_vmid.inspect}", status: 404)
        end

        if matches.length > 1
          candidates = matches.map { |r| "#{r["vmid"]} on #{r["node"]}" }.join(", ")
          raise AmbiguousMatchError,
            "VM name #{wanted.inspect} matches several VMs (#{candidates}); use the vmid"
        end

        entry = matches.first
        { vmid: entry["vmid"], node: entry["node"], name: entry["name"], status: entry["status"] }
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

      # Grow a virtual disk. +size+ uses Proxmox's own format: "+<n>[KMGT]" adds to the
      # current size, a bare "<n>[KMGT]" sets the new absolute size (Proxmox refuses to
      # shrink). PVE 8 runs the resize in a worker and returns a UPID; earlier releases do
      # the work inline and return nil — the caller decides whether there is a task to wait
      # on, since sequencing is not this class's job.
      def resize_disk(node:, vmid:, disk:, size:)
        @client.put("/nodes/#{enc(node)}/qemu/#{enc(vmid)}/resize", { disk:, size: })
      end

      # Start a VM. Returns the UPID of the async start task.
      def start(node:, vmid:)
        @client.post("/nodes/#{enc(node)}/qemu/#{enc(vmid)}/status/start")
      end

      # Hard-stop a VM (immediate power-off, like `qm stop` — NOT an ACPI shutdown).
      # Returns the UPID of the async stop task.
      def stop(node:, vmid:)
        @client.post("/nodes/#{enc(node)}/qemu/#{enc(vmid)}/status/stop")
      end

      # Gracefully shut a VM down via ACPI (like `qm shutdown`). +timeout+ (seconds) bounds
      # the wait inside the PVE task itself — without it the task waits indefinitely on a
      # guest that ignores the ACPI event. Returns the UPID of the async shutdown task.
      def shutdown(node:, vmid:, timeout: nil)
        @client.post(
          "/nodes/#{enc(node)}/qemu/#{enc(vmid)}/status/shutdown",
          { timeout: }.compact
        )
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
        expired = "task #{upid} did not finish within #{timeout}s"

        poll(timeout:, interval:, sleeper:, expired:) do
          status = task_status(node, upid)
          next false unless status["status"] == "stopped"

          raise_task_error(node, upid, status["exitstatus"]) unless status["exitstatus"] == "OK"
          true
        end
      end

      # Live power state of a VM ("running", "stopped", ...), read from its node.
      # /cluster/resources serves the status pvestatd caches every ~10 s, too stale to
      # decide on a power action.
      def vm_status(node:, vmid:)
        @client.get("/nodes/#{enc(node)}/qemu/#{enc(vmid)}/status/current")["status"]
      end

      # Poll #vm_status until it reports +status+. Returns true; raises TimeoutError once the
      # monotonic deadline passes. Needed after a power task on an HA-managed VM, whose task
      # only queues the request with the HA manager and finishes before the VM changes state.
      def wait_status(node:, vmid:, status:, timeout: DEFAULT_TIMEOUT, interval: DEFAULT_INTERVAL, sleeper: nil)
        expired = "VM #{vmid} did not reach #{status} within #{timeout}s"

        poll(timeout:, interval:, sleeper:, expired:) do
          vm_status(node:, vmid:) == status
        end
      end

      private

      # Run the block every +interval+ seconds until it returns true, raising TimeoutError
      # with +expired+ once the deadline passes. The block runs at least once.
      def poll(timeout:, interval:, sleeper:, expired:)
        sleeper ||= ->(seconds) { sleep(seconds) }
        deadline = monotonic_now + timeout

        loop do
          return true if yield
          raise TimeoutError, expired if monotonic_now >= deadline

          sleeper.call(interval)
        end
      end

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
