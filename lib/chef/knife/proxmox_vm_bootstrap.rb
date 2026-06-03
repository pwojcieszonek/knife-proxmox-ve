# frozen_string_literal: true

# Bootstrap is our superclass, so it must be loaded when this file is required — not lazily
# in deps. (knife loads bootstrap.rb first alphabetically today, but do not rely on that.)
require "chef/knife/bootstrap"

class Chef
  class Knife
    # `knife proxmox vm bootstrap NAME` — clone a Proxmox VE template, configure it,
    # start it, wait for the guest to come up, then bootstrap it with Chef/CINC.
    #
    # Subclasses Bootstrap (NOT Knife) so the whole post-provision lifecycle —
    # connect, register, render, upload, perform — is inherited. We only fill the
    # plugin hooks: setup, validate, create-instance, finalize. The clone→configure→
    # start→wait pipeline and the CLI surface come from ProxmoxVmProvision (shared with
    # `vm create`); this class adds the Chef bootstrap on top. The bootstrap target host
    # is unknown until the VM exists, so #validate_name_args! is a deliberate no-op and the
    # resolved IP is injected into @name_args in #plugin_create_instance!.
    class ProxmoxVmBootstrap < Chef::Knife::Bootstrap
      require_relative "helpers/proxmox_base"
      require_relative "helpers/proxmox_vm_provision"
      include Chef::Knife::ProxmoxBase
      include Chef::Knife::ProxmoxVmProvision

      # Bootstrap defaults to the community CINC build: a plain (even Chef-branded) knife then
      # installs cinc-client and never hits Chef's commercial license gate. Opt into Chef with
      # knife[:proxmox_bootstrap_product] = "chef" (or "chef-ice") in config.rb.
      CINC_PRODUCT = "cinc"
      CINC_INSTALL_URL = "https://omnitruck.cinc.sh/install.sh"

      # A freshly cloned VM often still runs cloud-init (which itself drives apt) when SSH first
      # answers. Installing the client then races cloud-init for the dpkg lock and fails
      # non-deterministically. Block on cloud-init completion before the omnibus install so a
      # single `vm bootstrap` is reliable. Guarded so non-cloud-init images don't error, and
      # `|| true` so a degraded/errored cloud-init state still lets the bootstrap proceed.
      CLOUD_INIT_WAIT_COMMAND =
        "if command -v cloud-init >/dev/null 2>&1; then cloud-init status --wait >/dev/null 2>&1 || true; fi"

      deps do
        require "chef/knife/bootstrap"
        Chef::Knife::Bootstrap.load_deps
        require "knife-proxmox-ve/api"
        require "knife-proxmox-ve/provisioner"
        require_relative "helpers/proxmox_base"
        require_relative "helpers/proxmox_vm_provision"
      end

      banner "knife proxmox vm bootstrap NAME (options)"

      # === Bootstrap lifecycle hooks ============================================

      # plugin_setup! is the first hook Bootstrap#run invokes, so the CINC default is applied
      # here — before render_template/perform_bootstrap build the omnibus install command. (In
      # older knife this was done from a fetch_license override; knife 19.2 dropped that hook
      # from the run sequence, so plugin_setup! is now the correct, earliest place.)
      def plugin_setup!
        default_bootstrap_to_cinc!
        config[:connection_protocol] ||= "ssh"
        config[:connection_port] ||= 22
        # TOFU: a freshly cloned VM has no entry in known_hosts. Accept its key on
        # first connect rather than failing the bootstrap or disabling verification.
        config[:ssh_verify_host_key] ||= :accept_new
        # Wait for cloud-init to finish before the bootstrap installs the client (see constant).
        config[:bootstrap_preinstall_command] ||= CLOUD_INIT_WAIT_COMMAND
      end

      # The bootstrap target host does not exist yet — it is resolved to the VM's IP
      # in #plugin_create_instance!. Override the inherited "must pass an FQDN" guard.
      def validate_name_args!; end

      def plugin_validate_options!
        validate_provision_options!(require_ssh_auth: true)
      end

      def plugin_create_instance!
        result = provision_vm!

        config[:chef_node_name] ||= @vm_name
        @name_args = [result.ip]
        @proxmox_result = result
      end

      def plugin_finalize
        result = @proxmox_result
        return unless result

        msg_provision_result(result)
        msg_pair("Chef node", config[:chef_node_name])
      end

      private

      # Plant the credential into cloud-init (via super) AND wire it into the bootstrap
      # connection so the inherited lifecycle can authenticate to the new VM.
      def apply_provision_auth!(spec)
        super

        config[:connection_password] = @cipassword if @cipassword

        return unless @ssh_public_key

        private_key = @ssh_public_key_path.sub(/\.pub\z/, "")
        config[:ssh_identity_file] ||= private_key if @ssh_public_key_path.end_with?(".pub") && File.exist?(private_key)
      end

      # Pin the bootstrap install to the CINC omnitruck unless the operator opted into Chef.
      # Setting bootstrap_url also short-circuits Bootstrap#fetch_license, so a Chef-branded
      # knife never prompts for (or fails on) a commercial license. An explicit
      # --bootstrap-product / --bootstrap-url / --bootstrap-install-command always wins.
      def default_bootstrap_to_cinc!
        return if config[:bootstrap_install_command]
        return if config[:bootstrap_product] || config[:bootstrap_url]

        product = Chef::Config[:knife][:proxmox_bootstrap_product]
        return if product && !cinc_product?(product) # opted into Chef: keep knife's defaults

        config[:bootstrap_product] = CINC_PRODUCT
        config[:bootstrap_url] = CINC_INSTALL_URL
      end

      def cinc_product?(product)
        product.to_s.strip.downcase == CINC_PRODUCT
      end
    end
  end
end
