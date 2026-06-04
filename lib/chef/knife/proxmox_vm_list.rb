# frozen_string_literal: true

require "chef/knife"
require_relative "helpers/proxmox_base"

class Chef
  class Knife
    # `knife proxmox vm list` — list the cluster's qemu VMs (templates excluded).
    #
    # Nested under Chef::Knife so the unqualified `include Knife::ProxmoxBase` resolves the
    # mixin (Chef::Knife::ProxmoxBase) through lexical scope. The CamelCase class name maps
    # to the command words: ProxmoxVmList -> "knife proxmox vm list".
    class ProxmoxVmList < Chef::Knife
      banner "knife proxmox vm list (options)"

      deps do
        require "knife-proxmox-ve/api"
        require_relative "helpers/proxmox_base"
      end

      include Knife::ProxmoxBase

      option :node,
        long:        "--node NODE",
        description: "Filter to one Proxmox node"

      def run
        unless name_args.empty?
          ui.error("knife proxmox vm list takes no arguments")
          show_usage
          exit 1
        end

        rows = proxmox_api.list_resources(template: false)
        rows = filter_by_node(rows)
        # Keep raw numbers for json/yaml (scripting); humanize only the rendered table.
        rows = rows.map { |row| humanize(row) } unless ui.interchange?
        ui.output(format_for_display(rows))
      end

      private

      def filter_by_node(rows)
        node = config[:node]
        return rows if node.nil? || node.to_s.empty?

        rows.select { |row| row[:node] == node }
      end

      def humanize(row)
        row.merge(
          maxmem:  human_bytes(row[:maxmem]),
          maxdisk: human_bytes(row[:maxdisk]),
          uptime:  human_duration(row[:uptime])
        )
      end
    end
  end
end
