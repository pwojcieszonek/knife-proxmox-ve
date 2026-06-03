# frozen_string_literal: true

require "chef/knife"

class Chef
  class Knife
    # `knife proxmox vm create NAME` — clone a Proxmox VE template, configure it, start it,
    # and wait for the guest to come up. Stops there: no Chef bootstrap runs.
    #
    # Subclasses plain Knife (NOT Bootstrap) — there is no post-provision lifecycle to
    # inherit. The clone→configure→start→wait pipeline and the CLI surface come from
    # ProxmoxVmProvision, shared with `vm bootstrap`. cloud-init auth is optional here: a
    # VM with a template-baked login is a valid result, so a missing --ssh-public-key /
    # cloud-init password is not fatal (unlike `vm bootstrap`, which must connect).
    #
    # The command never connects to the VM, so it does NOT wait for SSH and does NOT treat a
    # missing IP as failure (see #wait_for_ssh?/#require_ip?): its contract is "the VM is
    # cloned, configured and started". The IP is reported best-effort — known immediately for
    # a static --ip, or polled from the guest agent (bounded by --boot-timeout) for dhcp.
    class ProxmoxVmCreate < Chef::Knife
      require_relative "helpers/proxmox_base"
      require_relative "helpers/proxmox_vm_provision"
      include Chef::Knife::ProxmoxBase
      include Chef::Knife::ProxmoxVmProvision

      deps do
        require "knife-proxmox-ve/api"
        require "knife-proxmox-ve/provisioner"
        require_relative "helpers/proxmox_base"
        require_relative "helpers/proxmox_vm_provision"
      end

      banner "knife proxmox vm create NAME (options)"

      def run
        validate_provision_options!(require_ssh_auth: false)
        result = provision_vm!
        msg_provision_result(result)
      end

      private

      # No bootstrap connection is made, so creation must not block on SSH nor fail when the
      # VM has no reachable network. For dhcp the agent is still polled best-effort to report
      # an address; the poll is bounded by --boot-timeout and never fatal.
      def wait_for_ssh? = false
      def require_ip? = false
    end
  end
end
