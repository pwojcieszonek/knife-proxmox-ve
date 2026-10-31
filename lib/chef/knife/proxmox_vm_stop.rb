# frozen_string_literal: true

require "chef/knife"
require_relative "helpers/proxmox_base"
require_relative "helpers/proxmox_vm_power"

class Chef
  class Knife
    # `knife proxmox vm stop NAME_OR_VMID` — hard-stop a running VM (immediate power-off,
    # the API equivalent of `qm stop` — NOT an ACPI shutdown) and wait for the stop task
    # to finish. The target is a VM name or numeric vmid; an ambiguous name (Proxmox does
    # not enforce unique names) is an error, never a guess.
    class ProxmoxVmStop < Chef::Knife
      banner "knife proxmox vm stop NAME_OR_VMID (options)"

      deps do
        require "knife-proxmox-ve/api"
        require_relative "helpers/proxmox_base"
        require_relative "helpers/proxmox_vm_power"
      end

      include Knife::ProxmoxBase
      include Knife::ProxmoxVmPower

      def run
        power_action!(:stop, desired: "stopped")
      end
    end
  end
end
