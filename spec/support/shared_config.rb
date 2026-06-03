# frozen_string_literal: true

# Builds a valid knife[:proxmox_clusters] hash for use in examples. Mirrors the schema
# documented in the README / config.rb.
module SharedConfig
  module_function

  def clusters
    {
      "production" => {
        host:         "pve1.test",
        port:         8006,
        token_id:     "knife@pve!automation",
        token_secret: "00000000-1111-2222-3333-444444444444",
        verify_ssl:   true,
        storage:      "local-lvm",
        bridge:       "vmbr0",
        ciuser:       "ubuntu",
        nameserver:   "10.0.0.1",
        searchdomain: "example.test",
      },
      "lab" => {
        host:         "pve-lab.test",
        token_id:     "knife@pve!lab",
        token_secret: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
        verify_ssl:   false,
      },
    }
  end

  # Installs the cluster hash (and optional default) into Chef::Config[:knife].
  def install!(default: "production")
    Chef::Config[:knife][:proxmox_clusters] = clusters
    Chef::Config[:knife][:proxmox_default_cluster] = default if default
  end
end
