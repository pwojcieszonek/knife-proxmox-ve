# knife-proxmox-ve

A [knife](https://docs.chef.io/workstation/knife/) plugin (Chef Infra / CINC
Workstation) that **creates VMs on Proxmox VE** by cloning a pre-configured template,
configuring it, starting it, and waiting for it to boot. Use `vm create` to provision a
VM, or `vm bootstrap` to provision it **and automatically bootstrap it with Chef/CINC**
in one command.

The plugin only ever *clones* a prepared template; it never builds an image. All VM
parameters are optional: anything you don't pass keeps the value baked into the
template.

## Requirements

- Chef Workstation / CINC Workstation 18+ (the plugin depends on the `knife` gem ≥ 18).
- A Proxmox VE **API token** (see [Authentication](#authentication)).
- A template that already has a **cloud-init drive** (e.g. `ide2=<storage>:cloudinit`)
  and the **QEMU guest agent** enabled. Cloud-init settings are silently ignored by
  Proxmox if the template has no cloud-init drive — the plugin fails fast when it
  detects this.

## Installation

```bash
chef gem install knife-proxmox-ve     # Chef Workstation
cinc gem install knife-proxmox-ve     # CINC Workstation
```

knife discovers the commands automatically (no registration step). For development
from a checkout, run via `cinc exec bundle exec knife proxmox ...`.

## Configuration

Proxmox clusters are defined in `~/.cinc/config.rb` (or `~/.chef/config.rb`) under
`knife[:proxmox_clusters]`. Each key is a cluster name selectable with
`--proxmox-cluster`.

```ruby
knife[:proxmox_clusters] = {
  "production" => {
    host:         "pve1.example.com",    # required
    port:         8006,                  # optional (default 8006)
    token_id:     "knife@pve!automation", # required; the USER@REALM!TOKENID part
    token_secret: nil,                   # optional in-file; prefer the ENV override below
    verify_ssl:   true,                  # optional (default true); false warns every run

    # Optional per-cluster provisioning defaults (any CLI flag overrides these):
    storage:      "local-lvm",
    bridge:       "vmbr0",
    ciuser:       "ubuntu",
    nameserver:   "10.0.0.1",
    searchdomain: "example.com",
    target_node:  nil,
  },
}

# Cluster used when --proxmox-cluster is omitted:
knife[:proxmox_default_cluster] = "production"
```

### Authentication

The plugin authenticates with a Proxmox **API token** (`Authorization: PVEAPIToken=...`).
The token secret is resolved with this precedence (highest first):

1. `KNIFE_PROXMOX_TOKEN_SECRET` — global override for whichever cluster is selected
2. `KNIFE_PROXMOX_TOKEN_SECRET_<CLUSTER>` — per cluster (key upcased, non-alphanumerics → `_`)
3. `token_secret:` in the cluster hash

Prefer an environment variable so the secret never sits in a file. **If you do store
`token_secret:` in `config.rb`, `chmod 600 ~/.cinc/config.rb`** — anyone who can read
the file can read the token.

```bash
export KNIFE_PROXMOX_TOKEN_SECRET="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

> Proxmox API tokens default to **privilege separation**: a fresh token has no rights
> until you grant ACLs to the token itself. A first-run `HTTP 403` almost always means
> this. The token needs: `VM.Clone`, `VM.Config.Disk`, `VM.Config.Network`,
> `VM.Config.Memory`, `VM.Config.CPU`, `VM.Config.Cloudinit`, `VM.Config.Options`,
> `VM.PowerMgmt`, `VM.Audit`, `VM.Monitor` (guest-agent calls; PVE 8 and earlier),
> `VM.Allocate`, and `Datastore.AllocateSpace` on the target storage (full clones).

### TLS

HTTPS to `:8006` is verified by default. Set `verify_ssl: false` per cluster only for
self-signed lab hosts — the plugin warns on **every** command when verification is off,
because the connection (carrying the token) is then MITM-exploitable.

## Commands

### `knife proxmox vm create NAME`

Clone a template → configure → start. Stops there — **no Chef bootstrap runs**. Use it to
stand up a VM you do not (yet) want to manage with Chef. `NAME` (the new VM's name) and
`--template` are the only required inputs; every other parameter falls back to the template's
value.

Because it never connects to the VM, `vm create` does **not** wait for SSH and does **not**
fail if the guest has no network — its job is done once the VM is cloned, configured and
started. The IP is reported best-effort: known immediately for a static `--ip`, or polled
from the guest agent (bounded by `--boot-timeout`) for `dhcp`; if none is found it warns and
still succeeds, omitting the IP from the summary.

cloud-init auth (`--ssh-public-key` / `--cipassword`) is **optional** here: a template with
a baked-in login is a valid result. Pass a key/password if you want one planted on the guest.

```bash
knife proxmox vm create web-01 \
  --proxmox-cluster production \
  --template ubuntu-2404-template \
  --cores 2 --memory 4096 \
  --bridge vmbr0 --vlan 100 \
  --ip 10.0.10.50/24 --gateway 10.0.10.1 \
  --nameserver 10.0.0.1 --searchdomain example.com \
  --ciuser ubuntu --ssh-public-key ~/.ssh/id_ed25519.pub
```

### `knife proxmox vm bootstrap NAME`

Everything `vm create` does, then **bootstraps the node with Chef/CINC**: clone → configure →
start → wait for SSH → `knife bootstrap`. Because it must connect, an SSH public key or a
cloud-init password is **required**. `NAME` and `--template` are otherwise the only required
inputs; every other parameter falls back to the template's value.

```bash
knife proxmox vm bootstrap web-01 \
  --proxmox-cluster production \
  --template ubuntu-2404-template \
  --cores 2 --memory 4096 \
  --bridge vmbr0 --vlan 100 \
  --ip 10.0.10.50/24 --gateway 10.0.10.1 \
  --nameserver 10.0.0.1 --searchdomain example.com \
  --ciuser ubuntu --ssh-public-key ~/.ssh/id_ed25519.pub \
  --node web-01 --run-list 'role[base]'
```

Both commands share the provisioning flags below.

| Flag | Meaning |
|------|---------|
| `--template NAME_OR_VMID` | Source template (name or numeric VMID). **Required.** |
| `--proxmox-cluster NAME` | Cluster key from `knife[:proxmox_clusters]`. |
| `--target-node NODE` | Node to clone onto (requires shared storage for a cross-node clone). |
| `--newid VMID` | Use a specific VMID instead of the cluster's next free id. |
| `--linked-clone` | Linked clone instead of the default full clone (`--storage` is then ignored). |
| `--storage NAME` / `--pool NAME` | Target storage / resource pool. |
| `--cores N` / `--sockets N` / `--memory MiB` | CPU / RAM. |
| `--bridge vmbrN` / `--vlan TAG` | net0 bridge and VLAN tag (needs a VLAN-aware bridge). |
| `--ip CIDR\|dhcp` / `--gateway IP` / `--prefix N` | Static IPv4 (`10.0.10.5/24`, or a bare IP with `--prefix`) or `dhcp`. |
| `--nameserver IP` / `--searchdomain DOMAIN` | cloud-init DNS. |
| `--ciuser USER` | cloud-init user. |
| `--ssh-public-key PATH` | Public key injected via cloud-init (preferred auth). |
| `--cipassword` | Prompt (no echo) for a cloud-init password; or set `KNIFE_PROXMOX_CIPASSWORD`. |
| `--clone-timeout SEC` / `--boot-timeout SEC` | Clone and boot/SSH wait limits (default 600 / 300). |

For `vm bootstrap`, the standard `knife bootstrap` options are inherited: `-N/--node-name`,
`-r/--run-list`, `-E/--environment`, `--connection-user`, `--ssh-identity-file`,
`--bootstrap-version`, `--ssh-verify-host-key` (defaults to `:accept_new` for the
freshly-created host), `--yes`, etc. They do not apply to `vm create`, which never bootstraps.

**Clone mode.** The clone is a **full clone by default**. Pass `--linked-clone` for a linked
clone (faster, thin) — it requires a storage that supports it, and any `--storage` (CLI or
cluster default) is then dropped, because Proxmox rejects a target storage on a linked clone.

**Bootstrap product (CINC by default).** A `vm bootstrap`'d VM is bootstrapped with **CINC** out of the
box — the install is pinned to the CINC omnitruck regardless of whether you invoke a CINC- or
Chef-branded `knife`, which also avoids Chef's commercial license gate. To bootstrap with Chef
Infra Client instead, opt in via `config.rb`:

```ruby
knife[:proxmox_bootstrap_product] = "chef"   # or "chef-ice"; standard Chef licensing then applies
```

An explicit `--bootstrap-product`, `--bootstrap-url` or `--bootstrap-install-command` always wins.

**cloud-init wait.** Before installing the client, `vm bootstrap` waits for cloud-init to finish
(`cloud-init status --wait`) so the omnibus install never races cloud-init for the apt/dpkg lock
on the freshly booted VM. This makes `vm bootstrap` deterministic in a single run; override it
with `--bootstrap-preinstall-command` (it is skipped on images without cloud-init).

**SSH authentication.** Injecting a public key (`--ssh-public-key`) is the preferred path — for
`vm bootstrap` the matching private key is then used for the bootstrap connection. A cloud-init
password is supported as a fallback via `KNIFE_PROXMOX_CIPASSWORD` or the `--cipassword` no-echo
prompt (never as a literal command-line argument). A credential is **required** for `vm bootstrap`
(it must connect) and **optional** for `vm create`. For `--ip dhcp` the guest must run the QEMU
guest agent so the leased address can be discovered.

### `knife proxmox cluster list`

Lists the configured clusters with host, token id, `verify_ssl`, and whether a token
secret resolves (the secret value is never printed). Marks the default cluster with `*`.
Makes no API call.

### `knife proxmox template list [--proxmox-cluster NAME]`

Lists the qemu templates on the selected cluster (name, VMID, node, disk, memory).

### `knife proxmox vm list [--proxmox-cluster NAME] [--node NODE]`

Lists the cluster's qemu VMs (name, VMID, node, status, memory, uptime). `--node` filters
client-side.

Disk, memory and uptime are rendered human-readable (e.g. `10 GiB`, `1h`) in the default
table output. All read commands honour `--format json|yaml` for scripting, where these fields
stay raw (bytes / seconds).

## Development

Tests run under **cinc-workstation**, so the suite exercises the same `knife` build the
gem ships on (a cinc-internal build that differs from the rubygems release — e.g.
`Bootstrap#fetch_license` was removed in it). No bundler is involved.

```bash
cinc exec rake                      # chefstyle + rspec (the default task)
cinc exec rake spec                 # rspec only
cinc exec rake style                # chefstyle only
```

> Do **not** use `bundle exec` against cinc: `Gemfile.lock` pins the public knife, which the
> cinc gem repo does not carry, so `cinc exec bundle exec` fails. The `Gemfile`/`Gemfile.lock`
> exist only for `gem build`/release (`cinc exec rake build`).

## License

Apache-2.0.
