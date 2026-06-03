# frozen_string_literal: true

require "json"

# Canned Proxmox VE API JSON bodies for webmock stubs. Every Proxmox response wraps its
# payload in a top-level "data" key — use .wrap to mirror that envelope.
module ProxmoxResponses
  module_function

  def wrap(data)
    JSON.generate("data" => data)
  end

  # GET /cluster/resources?type=vm — a template and a running VM.
  def cluster_resources
    wrap([
      { "vmid" => 9000, "name" => "ubuntu-2404-template", "node" => "pve1", "type" => "qemu",
        "template" => 1, "status" => "stopped", "maxmem" => 2_147_483_648, "maxdisk" => 10_737_418_240 },
      { "vmid" => 101, "name" => "web-01", "node" => "pve1", "type" => "qemu",
        "template" => 0, "status" => "running", "maxmem" => 4_294_967_296, "uptime" => 3600 },
      { "vmid" => 200, "name" => "ct-dns", "node" => "pve2", "type" => "lxc",
        "template" => 0, "status" => "running" },
    ])
  end

  # A UPID task id of the canonical UPID:<node>:... shape.
  def upid(node: "pve1", type: "qmclone")
    "UPID:#{node}:00001234:00ABCDEF:00000000:#{type}:9000:knife@pve!automation:"
  end

  # GET /nodes/{node}/tasks/{upid}/status
  def task_status(running: false, exitstatus: "OK")
    data = { "upid" => upid, "status" => running ? "running" : "stopped" }
    data["exitstatus"] = exitstatus unless running
    wrap(data)
  end

  # GET /nodes/{node}/qemu/{vmid}/agent/network-get-interfaces
  def agent_interfaces(ip: "10.0.10.50")
    wrap({
      "result" => [
        { "name" => "lo", "ip-addresses" => [{ "ip-address" => "127.0.0.1", "ip-address-type" => "ipv4" }] },
        { "name" => "eth0", "hardware-address" => "aa:bb:cc:dd:ee:ff",
          "ip-addresses" => [
            { "ip-address" => "fe80::1", "ip-address-type" => "ipv6" },
            { "ip-address" => ip, "ip-address-type" => "ipv4", "prefix" => 24 },
          ] },
      ],
    })
  end

  # GET /cluster/nextid
  def next_id(id = 9001)
    wrap(id.to_s)
  end
end
