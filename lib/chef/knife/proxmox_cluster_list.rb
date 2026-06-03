# frozen_string_literal: true

require "chef/knife"
require_relative "helpers/proxmox_base"

class Chef
  class Knife
    # Lists the Proxmox clusters configured in knife[:proxmox_clusters].
    #
    # This is the one command that introspects configuration instead of calling the API:
    # it reads Chef::Config[:knife][:proxmox_clusters] directly and reports, per cluster,
    # whether a token secret resolves (via ENV override or the config file) WITHOUT ever
    # printing the secret value under any output format.
    class ProxmoxClusterList < Chef::Knife
      banner "knife proxmox cluster list (options)"

      deps do
        require "knife-proxmox-ve/api"
        require_relative "helpers/proxmox_base"
      end

      include Knife::ProxmoxBase

      def run
        unless name_args.empty?
          ui.error("This command takes no arguments")
          show_usage
          exit 1
        end

        clusters = Chef::Config[:knife][:proxmox_clusters] || {}
        if clusters.empty?
          ui.warn("no Proxmox clusters configured in knife[:proxmox_clusters]")
          return
        end

        ui.output(format_for_display(rows_for(clusters)))
      end

      private

      def rows_for(clusters)
        default_key = Chef::Config[:knife][:proxmox_default_cluster]

        clusters.map do |key, cluster|
          cluster = cluster.transform_keys(&:to_sym)
          {
            "cluster"         => row_key(key, default_key),
            "host"            => cluster[:host],
            "port"            => cluster.fetch(:port, 8006),
            "token_id"        => cluster[:token_id],
            "verify_ssl"      => cluster.fetch(:verify_ssl, true) != false,
            "secret_resolves" => proxmox_token_secret_present?(key.to_s, cluster),
            "default"         => default?(key, default_key),
          }
        end
      end

      def row_key(key, default_key)
        default?(key, default_key) ? "#{key} *" : key.to_s
      end

      def default?(key, default_key)
        return false if default_key.nil?

        default_key.to_s == key.to_s
      end
    end
  end
end
