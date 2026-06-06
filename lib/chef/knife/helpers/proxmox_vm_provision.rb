# frozen_string_literal: true

require "ipaddr" unless defined?(IPAddr)

class Chef
  class Knife
    # Shared provisioning concern for the `knife proxmox vm ...` commands that clone and
    # configure a VM. Owns the CLI surface and the clone→configure→start→wait pipeline so
    # both `vm create` (provision only) and `vm bootstrap` (provision + Chef bootstrap)
    # declare it once.
    #
    # The mixin is intentionally agnostic about whether a bootstrap follows: it resolves
    # cloud-init auth and plants it on the guest, but never touches the bootstrap connection.
    # The bootstrap command layers that on by overriding #apply_provision_auth!.
    module ProxmoxVmProvision
      # A bridge is any Linux network interface: a classic bridge (vmbr0), an SDN VNet
      # (arbitrary name, e.g. "mail"), an OVS bridge, a bond, etc. We only enforce what the
      # kernel itself does on an interface name — 1..15 chars, no whitespace, no "/", and not
      # "." or "..". IP/gateway validation is handled separately by IPAddr below.
      BRIDGE_PATTERN = %r{\A(?!\.{1,2}\z)[^\s/]{1,15}\z}

      # A pasted PRIVATE key must never travel as an authorized public key.
      PRIVATE_KEY_MARKER = /-----BEGIN [A-Z ]*PRIVATE KEY-----/

      # Public-key formats cloud-init understands.
      PUBLIC_KEY_PREFIXES = %w{ssh- ecdsa- sk- ssh-ed25519}.freeze

      # ENV override for the cloud-init password so it never lands in shell history.
      ENV_CIPASSWORD = "KNIFE_PROXMOX_CIPASSWORD"

      def self.included(includer)
        includer.class_eval do
          # --- Source template / clone placement --------------------------------

          option :template,
            long:        "--template NAME_OR_VMID",
            description: "Source template to clone (name or numeric VMID). Required."

          option :target_node,
            long:        "--target-node NODE",
            description: "Target node for the clone (migrate on clone). Defaults to the template's node."

          option :newid,
            long:        "--newid VMID",
            description: "VMID for the new VM. Defaults to the cluster's next free id."

          option :linked_clone,
            long:        "--linked-clone",
            description: "Linked clone instead of the default full clone " \
                         "(needs a storage that supports it; --storage is then ignored).",
            boolean:     true

          option :storage,
            long:        "--storage STORAGE",
            description: "Target storage for a full clone."

          option :pool,
            long:        "--pool POOL",
            description: "Resource pool to place the new VM in."

          # --- Hardware ---------------------------------------------------------

          option :cores,
            long:        "--cores N",
            description: "Number of CPU cores."

          option :sockets,
            long:        "--sockets N",
            description: "Number of CPU sockets."

          option :memory,
            long:        "--memory MiB",
            description: "Memory in MiB."

          # --- Networking -------------------------------------------------------

          option :bridge,
            long:        "--bridge NAME",
            description: "Network bridge for net0 (e.g. vmbr0 or an SDN VNet name)."

          option :vlan,
            long:        "--vlan TAG",
            description: "VLAN tag for net0."

          option :ip,
            long:        "--ip CIDR|IP|dhcp",
            description: "Static IP (CIDR or bare IPv4) or the literal 'dhcp'."

          option :gateway,
            long:        "--gateway IP",
            description: "Default gateway (IPv4)."

          option :prefix,
            long:        "--prefix N",
            description: "Netmask prefix length when --ip is a bare IPv4 (default 24)."

          option :nameserver,
            long:        "--nameserver IP",
            description: "cloud-init DNS nameserver."

          option :searchdomain,
            long:        "--searchdomain DOMAIN",
            description: "cloud-init DNS search domain."

          # --- cloud-init auth --------------------------------------------------

          option :ciuser,
            long:        "--ciuser USER",
            description: "cloud-init default user."

          option :ssh_public_key,
            long:        "--ssh-public-key PATH",
            description: "Path to an SSH PUBLIC key authorized for the cloud-init user."

          option :cipassword,
            long:        "--cipassword",
            description: "Prompt (no echo) for a cloud-init password. " \
                         "Prefer #{ENV_CIPASSWORD} in the environment.",
            boolean:     true

          # --- Timeouts ---------------------------------------------------------

          option :clone_timeout,
            long:        "--clone-timeout SECONDS",
            description: "Seconds to wait for the clone task (default 600).",
            default:     600

          option :boot_timeout,
            long:        "--boot-timeout SECONDS",
            description: "Seconds to wait for the guest to boot and open SSH (default 300).",
            default:     300
        end
      end

      private

      # Resolve and validate everything the clone pipeline needs, except auth. Sets @vm_name
      # and @cluster_config. Fatals loudly on the first problem. require_ssh_auth controls
      # whether a missing SSH credential is fatal (true for bootstrap, false for plain create).
      def validate_provision_options!(require_ssh_auth:)
        @vm_name = name_args.first
        ui.fatal!("You must supply a VM NAME") if blank?(@vm_name)
        ui.fatal!("--template NAME_OR_VMID is required") if blank?(config[:template])

        @cluster_config = proxmox_cluster_config

        validate_scalars!
        validate_network!
        resolve_ssh_auth!(require_credential: require_ssh_auth)
        true
      end

      # Build the spec, plant the resolved cloud-init auth, and run the clone pipeline.
      # Returns the Provisioner::Result.
      def provision_vm!
        spec = build_spec
        apply_provision_auth!(spec)

        # Anchor at top level: inside Chef::Knife, a bare Knife resolves to Chef::Knife.
        ::Knife::Proxmox::Provisioner.new(proxmox_api, ui:).provision(spec)
      end

      # Print the provisioned VM identity. Shared by `vm create`'s #run and `vm bootstrap`'s
      # #plugin_finalize.
      def msg_provision_result(result)
        msg_pair("VM name", @vm_name)
        msg_pair("VMID", result.vmid)
        msg_pair("Node", result.node)
        msg_pair("IP", result.ip)
      end

      # --- Validation ---------------------------------------------------------

      def validate_scalars!
        # Timeouts always carry an integer default, but a CLI override (--boot-timeout 180)
        # arrives as a String — coerce it here so the Provisioner's deadline arithmetic
        # (monotonic_now + timeout) never hits "String can't be coerced into Float".
        %i{cores sockets memory prefix clone_timeout boot_timeout}.each do |key|
          next unless config.key?(key) && !config[key].nil?

          config[key] = positive_integer!(key, config[key])
        end

        return if config[:vlan].nil?

        config[:vlan] = integer!(:vlan, config[:vlan])
      end

      def validate_network!
        validate_bridge!
        validate_ip!
        validate_gateway!
      end

      def validate_bridge!
        bridge = config[:bridge]
        return if bridge.nil?
        return if BRIDGE_PATTERN.match?(bridge)

        ui.fatal!("--bridge #{bridge.inspect} is not a valid interface name " \
                  "(1-15 chars, no whitespace or '/'; e.g. vmbr0 or an SDN VNet name)")
      end

      def validate_ip!
        ip = config[:ip]
        return if ip.nil? || ip == "dhcp"

        addr = IPAddr.new(ip)
        ui.fatal!("--ip #{ip.inspect} must be an IPv4 address/CIDR (ipconfig0 is IPv4 here)") unless addr.ipv4?
      rescue IPAddr::Error
        ui.fatal!("--ip #{ip.inspect} is not 'dhcp' nor a valid IPv4 address/CIDR")
      end

      def validate_gateway!
        gateway = config[:gateway]
        return if gateway.nil?

        addr = IPAddr.new(gateway)
        ui.fatal!("--gateway #{gateway.inspect} must be an IPv4 address") unless addr.ipv4?
      rescue IPAddr::Error
        ui.fatal!("--gateway #{gateway.inspect} is not a valid IPv4 address")
      end

      def positive_integer!(key, value)
        int = integer!(key, value)
        ui.fatal!("--#{key.to_s.tr("_", "-")} must be greater than 0 (got #{int})") unless int > 0
        int
      end

      def integer!(key, value)
        Integer(value.to_s, 10)
      rescue ArgumentError
        ui.fatal!("--#{key.to_s.tr("_", "-")} must be an integer (got #{value.inspect})")
      end

      # --- cloud-init auth ----------------------------------------------------

      # Resolve the cloud-init password and SSH public key into @cipassword/@ssh_public_key.
      # When require_credential is set, fatals if neither is available (bootstrap needs one to
      # connect); otherwise both staying nil is fine (a plain clone with template-baked auth).
      def resolve_ssh_auth!(require_credential:)
        @cipassword = resolve_cipassword
        @ssh_public_key = resolve_ssh_public_key

        return unless require_credential
        return if @ssh_public_key || @cipassword

        ui.fatal!(
          "no SSH credential for the new VM: pass --ssh-public-key PATH, or provide a " \
          "cloud-init password via #{ENV_CIPASSWORD} or --cipassword"
        )
      end

      def resolve_cipassword
        from_env = present(ENV[ENV_CIPASSWORD])
        return from_env if from_env
        return nil unless config[:cipassword]

        prompted = ui.ask("Enter cloud-init password: ", echo: false)
        present(prompted)
      end

      # Reads the public key file, fatals if unreadable, and rejects anything that
      # looks like a private key (a common copy-paste mistake that must never be
      # uploaded as an authorized key).
      def resolve_ssh_public_key
        path = config[:ssh_public_key]
        return nil if blank?(path)

        @ssh_public_key_path = File.expand_path(path)
        ui.fatal!("--ssh-public-key #{path}: file not readable") unless File.readable?(@ssh_public_key_path)

        content = File.read(@ssh_public_key_path).strip
        if PRIVATE_KEY_MARKER.match?(content)
          ui.fatal!("--ssh-public-key #{path} is a PRIVATE key; pass the PUBLIC key (.pub) instead")
        end
        unless PUBLIC_KEY_PREFIXES.any? { |prefix| content.start_with?(prefix) }
          ui.fatal!("--ssh-public-key #{path} is not a recognized public key (expected ssh-/ecdsa-/sk-/ssh-ed25519)")
        end

        content
      end

      # Plant the resolved credential into the provisioner spec so cloud-init lays it down on
      # the guest. Secrets never go through the query string. The bootstrap command overrides
      # this to ALSO wire the credential into its bootstrap connection.
      def apply_provision_auth!(spec)
        spec[:config][:cipassword] = @cipassword if @cipassword
        spec[:config][:ssh_public_key] = @ssh_public_key if @ssh_public_key
      end

      # --- Provisioner spec assembly ------------------------------------------

      def build_spec
        full = !config[:linked_clone]
        warn_storage_ignored_for_linked_clone! unless full
        {
          name:          @vm_name,
          template:      proxmox_api.find_template(config[:template]),
          newid:         config[:newid].nil? ? nil : integer!(:newid, config[:newid]),
          target_node:   from_cli_or_cluster(:target_node),
          full:,
          # Proxmox rejects a target storage for a linked clone, so it is sent for full
          # clones only — for a linked clone the CLI/cluster storage is dropped entirely.
          storage:       full ? from_cli_or_cluster(:storage) : nil,
          pool:          config[:pool],
          clone_timeout: config[:clone_timeout],
          boot_timeout:  config[:boot_timeout],
          # Post-start wait policy (see Provisioner#wait_for_ip). Defaults suit bootstrap;
          # `vm create` overrides both to decouple success from SSH/network reachability.
          wait_for_ssh:  wait_for_ssh?,
          require_ip:    require_ip?,
          config:        build_provision_config,
        }
      end

      # Whether the post-start wait should block until SSH (port 22) is reachable. Bootstrap
      # must connect, so it waits; `vm create` overrides this to false.
      def wait_for_ssh? = true

      # Whether a VM that never reports a usable IPv4 is a failure. Bootstrap needs an address
      # to connect, so it is; `vm create` overrides this to false (best-effort IP).
      def require_ip? = true

      # The cluster-default storage is dropped silently for a linked clone, but an explicit
      # --storage deserves a heads-up that Proxmox will not honor it there.
      def warn_storage_ignored_for_linked_clone!
        return if config[:storage].nil?

        ui.warn("--storage is ignored for a --linked-clone")
      end

      def build_provision_config
        {
          cores:         config[:cores],
          sockets:       config[:sockets],
          memory:        config[:memory],
          bridge:        from_cli_or_cluster(:bridge),
          vlan:          config[:vlan],
          ip:            config[:ip],
          gateway:       config[:gateway],
          prefix:        config[:prefix],
          ciuser:        from_cli_or_cluster(:ciuser),
          nameserver:    from_cli_or_cluster(:nameserver),
          searchdomain:  from_cli_or_cluster(:searchdomain),
        }.compact
      end

      # Single point of cli-over-cluster-default resolution. The cluster hash uses the
      # same symbol keys (see SharedConfig / proxmox_base).
      def from_cli_or_cluster(key)
        value = config[key]
        return value unless value.nil?

        @cluster_config[key]
      end

      def blank?(value)
        value.nil? || value.to_s.empty?
      end
    end
  end
end
