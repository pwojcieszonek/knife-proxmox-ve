# frozen_string_literal: true

require "chef/knife"
require_relative "helpers/proxmox_base"
require_relative "helpers/proxmox_vm_power"

class Chef
  class Knife
    # `knife proxmox vm start NAME_OR_VMID` — start a stopped VM and wait for the start
    # task to finish. The target is a VM name or numeric vmid; an ambiguous name (Proxmox
    # does not enforce unique names) is an error, never a guess.
    class ProxmoxVmStart < Chef::Knife
      banner "knife proxmox vm start NAME_OR_VMID (options)"

      deps do
        require "knife-proxmox-ve/api"
        require_relative "helpers/proxmox_base"
        require_relative "helpers/proxmox_vm_power"
      end

      include Knife::ProxmoxBase
      include Knife::ProxmoxVmPower

      def run
        power_action!(:start, desired: "running")
      end
    end
  end
end
