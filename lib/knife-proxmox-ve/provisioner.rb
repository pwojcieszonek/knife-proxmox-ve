# frozen_string_literal: true

require "erb" unless defined?(ERB)
require "socket" unless defined?(Socket)

require "knife-proxmox-ve/api"
require "knife-proxmox-ve/errors"

module Knife
  module Proxmox
    # The single place the clone -> configure -> start -> wait-for-IP sequence lives, and
    # the one place cloud-init param encoding policy is defined. Everything that requires
    # ordering between Api round-trips belongs here; Api itself stays stateless.
    #
    # Dependencies are injected so the whole sequence is testable without sockets or sleeps:
    #   * +api+        — Knife::Proxmox::Api
    #   * +ui+         — duck-typed #info/#warn sink (optional; progress is best-effort)
    #   * +port_check+ — ->(host, port) { bool }; defaults to a real, short TCP connect
    #   * +sleeper+    — ->(seconds) {}; defaults to Kernel#sleep
    class Provisioner
      # IDs we hand back to the caller after a successful provision.
      Result = Struct.new(:vmid, :node, :ip, keyword_init: true)

      # Backoff between TCP/agent polls while waiting for the guest to come up.
      POLL_INTERVAL = 2

      # Time budget for a single TCP connect probe.
      PORT_CHECK_TIMEOUT = 2

      # A cloud-init drive lives on one of these controllers with a value naming "cloudinit".
      CLOUDINIT_DRIVE_KEY = /\A(?:ide|scsi|sata)\d+\z/
      CLOUDINIT_DRIVE_VALUE = /cloudinit/

      # Proxmox reports a VMID collision as a non-2xx body mentioning the existing id.
      DUPLICATE_ID = /already exists|config file already exists|VM \d+ already/i

      def initialize(api, ui: nil, port_check: nil, sleeper: nil)
        @api = api
        @ui = ui
        @port_check = port_check || method(:tcp_open?)
        @sleeper = sleeper || ->(seconds) { sleep(seconds) }
      end

      # Run the full provisioning sequence for +spec+ (see the class header / WU contract for
      # its shape). Returns a Result; raises Knife::Proxmox::* loudly on any failure.
      def provision(spec)
        template = spec.fetch(:template)
        newid = clone_with_retry(spec, template)
        node = spec[:target_node] || template[:node]

        params = build_config(spec.fetch(:config, {}) || {})
        guard_cloud_init_drive!(node, newid, spec[:name]) if cloud_init?(params)
        @api.update_config(node:, vmid: newid, **params) unless params.empty?

        boot(node, newid)
        ip = wait_for_ip(spec, node, newid)

        Result.new(vmid: newid, node:, ip:)
      end

      private

      # Resolve the new VMID, clone the template, and wait for the clone task. When the id was
      # auto-assigned and Proxmox rejects it as already-taken, fetch a fresh id and retry once
      # — a benign race against a concurrent allocation, not a fatal condition.
      def clone_with_retry(spec, template)
        auto = spec[:newid].nil?
        newid = spec[:newid] || @api.next_id
        clone_once(spec, template, newid)
        newid
      rescue Knife::Proxmox::ApiError, Knife::Proxmox::TaskError => e
        raise unless auto && duplicate_id?(e)
        raise if @clone_retried

        @clone_retried = true
        @ui&.warn("VMID #{newid} already taken, retrying with a fresh id")
        retry
      end

      def clone_once(spec, template, newid)
        @ui&.info("Cloning #{template[:vmid]} -> #{newid} (#{spec[:name]})...")
        params = {
          name:    spec[:name],
          target:  spec[:target_node],
          full:    (spec[:full] ? 1 : nil),
          storage: spec[:storage],
          pool:    spec[:pool],
        }.compact
        upid = @api.clone(node: template[:node], vmid: template[:vmid], newid:, **params)
        @ui&.info("Waiting for clone task...")
        # wait_task parses the source node from the UPID itself — do not pass a node.
        @api.wait_task(upid:, timeout: spec[:clone_timeout])
      end

      def duplicate_id?(error)
        DUPLICATE_ID.match?(error.message.to_s)
      end

      # Build the qemu config params from the cloud-init/hardware subset. Only keys that are
      # actually present are emitted, so a partial spec never clears unrelated VM config.
      def build_config(config)
        params = {}
        %i{cores sockets memory ciuser cipassword nameserver searchdomain}.each do |key|
          value = config[key]
          params[key] = value unless value.nil?
        end

        net0 = build_net0(config)
        params[:net0] = net0 if net0
        ipconfig0 = build_ipconfig0(config)
        params[:ipconfig0] = ipconfig0 if ipconfig0
        sshkeys = build_sshkeys(config)
        params[:sshkeys] = sshkeys if sshkeys

        params
      end

      # Emit net0 only when bridge or vlan is given; otherwise the template's net0 (and its
      # MAC) is preserved. Never emit a dangling "tag=" with no value.
      def build_net0(config)
        bridge = config[:bridge]
        vlan = config[:vlan]
        return nil unless bridge || vlan

        value = "model=virtio"
        value += ",bridge=#{bridge}" if bridge
        value += ",tag=#{vlan}" if vlan
        value
      end

      def build_ipconfig0(config)
        ip = config[:ip]
        return nil if ip.nil?
        return "ip=dhcp" if ip == "dhcp"

        cidr = ip.include?("/") ? ip : "#{ip}/#{config[:prefix] || 24}"
        value = "ip=#{cidr}"
        gateway = config[:gateway]
        value += ",gw=#{gateway}" if gateway
        value
      end

      def build_sshkeys(config)
        key = config[:ssh_public_key]
        return nil if key.nil?

        ERB::Util.url_encode(key.strip)
      end

      # Any of these params means cloud-init must actually be honored by the guest, which it
      # cannot be without a cloud-init drive on the cloned VM.
      def cloud_init?(params)
        params.key?(:ciuser) || params.key?(:cipassword) || params.key?(:sshkeys) ||
          params.key?(:ipconfig0) || params.key?(:nameserver) || params.key?(:searchdomain)
      end

      # Fail fast before a doomed bootstrap: if the (template-derived) VM has no cloud-init
      # drive, the keys we are about to set would be silently ignored by the guest.
      def guard_cloud_init_drive!(node, vmid, name)
        config = @api.vm_config(node:, vmid:)
        present = config.any? do |key, value|
          CLOUDINIT_DRIVE_KEY.match?(key.to_s) && CLOUDINIT_DRIVE_VALUE.match?(value.to_s)
        end
        return if present

        raise Knife::Proxmox::Error,
          "template #{name} has no cloud-init drive (ide2=<storage>:cloudinit); " \
          "cloud-init settings would be silently ignored"
      end

      def boot(node, vmid)
        @ui&.info("Starting VM #{vmid}...")
        upid = @api.start(node:, vmid:)
        @ui&.info("Waiting for start task...")
        @api.wait_task(upid:)
      end

      # Resolve the guest IP and (for bootstrap) confirm SSH is reachable within boot_timeout.
      # A static IP is authoritative from the spec (no read-back from Proxmox); dhcp/absent
      # polls the agent.
      #
      # Two spec flags tune this for callers that do not bootstrap (e.g. `vm create`):
      #   * wait_for_ssh: (default true) — block until port 22 opens. A plain create has no
      #     connection to make, so it sets false and never couples success to SSH reachability.
      #   * require_ip:   (default true) — when the agent reports no IPv4 before the timeout,
      #     raise (bootstrap needs an address to connect). A plain create sets false: it warns
      #     and returns nil, so a network-less or agent-less VM is still a successful create.
      def wait_for_ip(spec, node, vmid)
        timeout = spec.fetch(:boot_timeout)
        config = spec.fetch(:config, {}) || {}
        ip = config[:ip]
        wait_ssh = spec.fetch(:wait_for_ssh, true)
        require_ip = spec.fetch(:require_ip, true)

        if static_ip?(ip)
          address = ip.split("/").first
          wait_for_port(address, timeout) if wait_ssh
          return address
        end

        deadline = monotonic_now + timeout
        loop do
          address = discover_agent_ip(node, vmid)
          if address
            remaining = deadline - monotonic_now
            wait_for_port(address, [remaining, 0].max) if wait_ssh
            return address
          end

          if monotonic_now >= deadline
            if require_ip
              raise Knife::Proxmox::TimeoutError,
                "VM #{vmid} reported no usable IPv4 within #{timeout}s"
            end

            @ui&.warn("VM #{vmid} reported no usable IPv4 within #{timeout}s; created without an IP")
            return nil
          end

          @sleeper.call(POLL_INTERVAL)
        end
      end

      def static_ip?(ip)
        !ip.nil? && ip != "dhcp"
      end

      # The guest agent may not be up yet; treat its "not available" errors as "keep polling"
      # rather than a hard failure — only the boot_timeout deadline ends the wait.
      def discover_agent_ip(node, vmid)
        @api.agent_ip_addresses(node:, vmid:).find { |ip| ipv4?(ip) }
      rescue Knife::Proxmox::ApiError
        nil
      end

      def wait_for_port(host, timeout)
        @ui&.info("Waiting for SSH on #{host}...")
        deadline = monotonic_now + timeout
        loop do
          return if @port_check.call(host, 22)

          if monotonic_now >= deadline
            raise Knife::Proxmox::TimeoutError,
              "SSH port 22 on #{host} not reachable within the boot timeout"
          end

          @sleeper.call(POLL_INTERVAL)
        end
      end

      def ipv4?(ip)
        ip.include?(".") && !ip.include?(":")
      end

      def tcp_open?(host, port)
        Socket.tcp(host, port, connect_timeout: PORT_CHECK_TIMEOUT) { true }
      rescue SystemCallError, SocketError, IOError
        false
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
