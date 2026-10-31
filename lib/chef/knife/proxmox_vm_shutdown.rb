# frozen_string_literal: true

require "chef/knife"
require_relative "helpers/proxmox_base"
require_relative "helpers/proxmox_vm_power"

class Chef
  class Knife
    # `knife proxmox vm shutdown NAME_OR_VMID` — gracefully shut a running VM down via
    # ACPI (the API equivalent of `qm shutdown`; `vm stop` is the hard power-off) and
    # wait for the shutdown task. --timeout is also sent to the endpoint, bounding the
    # ACPI wait inside the PVE task — a guest that ignores the event fails the task
    # loudly instead of leaving it hanging. The target is a VM name or numeric vmid; an
    # ambiguous name (Proxmox does not enforce unique names) is an error, never a guess.
    class ProxmoxVmShutdown < Chef::Knife
      banner "knife proxmox vm shutdown NAME_OR_VMID (options)"

      deps do
        require "knife-proxmox-ve/api"
        require_relative "helpers/proxmox_base"
        require_relative "helpers/proxmox_vm_power"
      end

      include Knife::ProxmoxBase
      include Knife::ProxmoxVmPower

      def run
        power_action!(:shutdown, desired: "stopped", api_timeout: true)
      end
    end
  end
end
