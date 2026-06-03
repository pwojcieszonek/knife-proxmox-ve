# frozen_string_literal: true

require "chef/knife"
require_relative "helpers/proxmox_base"

# Nested so the unqualified `include Knife::ProxmoxBase` resolves through lexical scope
# to Chef::Knife::ProxmoxBase. The CamelCase name maps to "knife proxmox template list".
class Chef
  class Knife
    # List the qemu templates available on the selected Proxmox cluster. Read-only: a single
    # /cluster/resources round-trip filtered to templates, rendered through knife's display
    # pipeline so --format json|yaml works out of the box.
    class ProxmoxTemplateList < Chef::Knife
      banner "knife proxmox template list (options)"

      deps do
        require "knife-proxmox-ve/api"
        require_relative "helpers/proxmox_base"
      end

      include Knife::ProxmoxBase

      def run
        unless name_args.empty?
          ui.error("knife proxmox template list takes no arguments")
          show_usage
          exit 1
        end

        rows = proxmox_api.list_resources(template: true).map do |resource|
          {
            name:    resource[:name],
            vmid:    resource[:vmid],
            node:    resource[:node],
            maxdisk: resource[:maxdisk],
            maxmem:  resource[:maxmem],
          }
        end

        ui.output(format_for_display(rows))
      end
    end
  end
end
