# frozen_string_literal: true

require "knife-proxmox-ve/client"
require "knife-proxmox-ve/api"

class Chef
  class Knife
    # Shared behaviour mixed into every `knife proxmox ...` command (SEAM 2).
    #
    # Owns cluster resolution, the Client/Api factory and the secret-from-ENV override so
    # individual commands stay declarative: they call #proxmox_api, #proxmox_client and
    # #msg_pair and never touch the clusters hash or the environment directly.
    #
    # The token secret is resolved with ENV precedence and is never sent empty — a missing
    # secret is a loud, fatal error, not a silent default.
    module ProxmoxBase
      # Global ENV override applied to whichever cluster is selected.
      ENV_SECRET_GLOBAL = "KNIFE_PROXMOX_TOKEN_SECRET"

      # Per-cluster ENV override prefix; suffix is the cluster key normalized via #env_key.
      ENV_SECRET_PREFIX = "KNIFE_PROXMOX_TOKEN_SECRET_"

      def self.included(includer)
        includer.class_eval do
          option :proxmox_cluster,
            long:        "--proxmox-cluster NAME",
            description: "Proxmox cluster key from knife[:proxmox_clusters]"
        end
      end

      # The selected cluster as a symbol-keyed Hash, with :token_secret resolved through the
      # ENV override. Fatals (and lists available keys) when no cluster is selected or the
      # selected key is unknown. Memoized.
      def proxmox_cluster_config
        @proxmox_cluster_config ||= resolve_cluster_config
      end

      # The transport client for the selected cluster. Warns on every run when TLS
      # verification is disabled. Memoized.
      def proxmox_client
        @proxmox_client ||= build_proxmox_client
      end

      # The endpoint map over #proxmox_client. Memoized.
      def proxmox_api
        # Anchor at top level: inside Chef::Knife, a bare Knife resolves to Chef::Knife.
        @proxmox_api ||= ::Knife::Proxmox::Api.new(proxmox_client)
      end

      # Print a colored "label: value" line, skipping blank values. Not a knife-core helper;
      # commands depend on it being defined here.
      def msg_pair(label, value, color = :cyan)
        ui.info("#{ui.color(label, color)}: #{value}") if value && !value.to_s.empty?
      end

      # Binary byte units, lowest first. Proxmox reports sizes in bytes against a 1024 base,
      # so render in IEC units (KiB, MiB, ...) to match the values shown in the Proxmox UI.
      BYTE_UNITS = %w{B KiB MiB GiB TiB PiB}.freeze

      # Render a byte count as a human-readable IEC size (e.g. 10_737_418_240 -> "10 GiB").
      # Passes nil through untouched so absent fields (a template has no live size) stay nil
      # rather than becoming a misleading "0 B".
      def human_bytes(value)
        return value if value.nil?

        size = value.to_f
        unit = 0
        while size >= 1024 && unit < BYTE_UNITS.length - 1
          size /= 1024
          unit += 1
        end
        format("%g %s", size.round(2), BYTE_UNITS[unit])
      end

      # Render a second count as a compact duration (e.g. 3600 -> "1h", 90_061 -> "1d 1h 1m 1s").
      # nil passes through (a stopped/template VM reports no uptime); 0 renders as "0s".
      def human_duration(seconds)
        return seconds if seconds.nil?

        days, rest = seconds.to_i.divmod(86_400)
        hours, rest = rest.divmod(3_600)
        minutes, secs = rest.divmod(60)

        parts = []
        parts << "#{days}d" if days > 0
        parts << "#{hours}h" if hours > 0
        parts << "#{minutes}m" if minutes > 0
        parts << "#{secs}s" if secs > 0 || parts.empty?
        parts.join(" ")
      end

      # Whether a token secret resolves for the given cluster (symbol-keyed hash), using the
      # same precedence as #resolve_token_secret but without fatal-ing. Lets `cluster list`
      # report secret presence from a single source of truth.
      def proxmox_token_secret_present?(cluster_key, cluster_hash)
        !token_secret_from_sources(cluster_key, cluster_hash).nil?
      end

      private

      def resolve_cluster_config
        cluster_key = config[:proxmox_cluster] || Chef::Config[:knife][:proxmox_default_cluster]
        if cluster_key.nil? || cluster_key.to_s.empty?
          ui.fatal!(
            "no Proxmox cluster selected: pass --proxmox-cluster NAME or set " \
            "knife[:proxmox_default_cluster]. Available: #{available_cluster_keys}"
          )
        end

        cluster = proxmox_clusters[cluster_key.to_s] || proxmox_clusters[cluster_key.to_sym]
        unless cluster
          ui.fatal!(
            "unknown Proxmox cluster #{cluster_key.inspect}. " \
            "Available: #{available_cluster_keys}"
          )
        end

        cluster = cluster.transform_keys(&:to_sym)
        cluster[:token_secret] = resolve_token_secret(cluster_key.to_s, cluster)
        cluster
      end

      def build_proxmox_client
        cluster = proxmox_cluster_config
        verify_ssl = cluster.fetch(:verify_ssl, true) != false
        ui.warn(tls_disabled_warning(cluster)) unless verify_ssl

        # Anchor at top level: inside Chef::Knife, a bare Knife resolves to Chef::Knife.
        ::Knife::Proxmox::Client.new(
          host:         cluster[:host],
          token_id:     cluster[:token_id],
          token_secret: cluster[:token_secret],
          port:         cluster.fetch(:port, 8006),
          verify_ssl:
        )
      end

      def proxmox_clusters
        # The nested clusters hash has no CLI equivalent; read it straight from Chef::Config.
        Chef::Config[:knife][:proxmox_clusters] || {}
      end

      # Resolve the token secret or fatal, so an empty secret never reaches the wire.
      def resolve_token_secret(cluster_key, cluster_hash)
        guard_env_key_collisions

        secret = token_secret_from_sources(cluster_key, cluster_hash)
        unless secret
          ui.fatal!(
            "no Proxmox token secret for cluster #{cluster_key.inspect}: set #{ENV_SECRET_GLOBAL}, " \
            "#{per_cluster_env_var(cluster_key)}, or knife[:proxmox_clusters][#{cluster_key.inspect}][:token_secret]"
          )
        end

        secret
      end

      # Token-secret precedence: global ENV, then per-cluster ENV, then the config file.
      # The single source of truth for the precedence order (reused by the presence check).
      def token_secret_from_sources(cluster_key, cluster_hash)
        present(ENV[ENV_SECRET_GLOBAL]) ||
          present(ENV[per_cluster_env_var(cluster_key)]) ||
          present(cluster_hash[:token_secret])
      end

      # The per-cluster ENV var name for a given cluster key.
      def per_cluster_env_var(cluster_key)
        "#{ENV_SECRET_PREFIX}#{env_key(cluster_key)}"
      end

      # Normalize a cluster key into an ENV-var-safe suffix: upcase, non-alphanumeric -> "_".
      def env_key(cluster_key)
        cluster_key.to_s.upcase.gsub(/[^A-Z0-9]/, "_")
      end

      # Fatal if two configured cluster keys collapse to the same per-cluster ENV var name,
      # because an override meant for one would silently apply to the other.
      def guard_env_key_collisions
        groups = proxmox_clusters.keys.group_by { |key| env_key(key) }
        collision = groups.find { |_normalized, keys| keys.length > 1 }
        return unless collision

        normalized, keys = collision
        ui.fatal!(
          "Proxmox cluster keys #{keys.map(&:to_s).sort.inspect} both map to ENV var " \
          "#{ENV_SECRET_PREFIX}#{normalized}; rename one to disambiguate the per-cluster secret override"
        )
      end

      def available_cluster_keys
        keys = proxmox_clusters.keys.map(&:to_s).sort
        keys.empty? ? "(none configured)" : keys.join(", ")
      end

      def present(value)
        return nil if value.nil?

        str = value.to_s
        str.empty? ? nil : value
      end

      def tls_disabled_warning(cluster)
        "TLS certificate verification is DISABLED for Proxmox host " \
          "#{cluster[:host]} (verify_ssl: false) — connection is vulnerable to MITM"
      end
    end
  end
end
