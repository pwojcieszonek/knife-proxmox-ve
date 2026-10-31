# knife-proxmox-ve

Knife plugin gem: clones Proxmox VE templates into VMs (`vm create`) and
optionally bootstraps them with Chef/CINC (`vm bootstrap`). Published to
rubygems.org.

## Commands

The dev toolchain is cinc-workstation's embedded Ruby. Do not use bundler,
rvm, or the system Ruby here, even though `.ruby-version`/`.ruby-gemset`
exist: the rvm path hits Chef's license gate and runs a different knife
build than the one the gem ships on.

```bash
cinc exec rake                        # chefstyle + full rspec suite (default task)
cinc exec rake spec                   # rspec only
cinc exec rake style                  # chefstyle (RuboCop ruleset) only
cinc exec rspec spec/unit/api_spec.rb # single spec file
cinc exec env RUBYLIB="$PWD/lib" knife proxmox vm list   # run the checkout live
```

`cinc exec bundle exec` fails with `Bundler::GemNotFound`, and the lock
cannot be "fixed": Gemfile.lock resolves knife from rubygems.org (19.0.x)
while cinc ships an internal knife build (19.2.x) that rubygems does not
carry. The builds also differ in API (the cinc build dropped
`Bootstrap#fetch_license`), so verify knife internals against the cinc
build, not against rubygems sources. Gemfile/Gemfile.lock exist only for
`rake build` / `rake release`.

## Architecture

Hard boundary: `lib/knife-proxmox-ve/` (errors, Client, Api, Provisioner)
uses only the Ruby stdlib and must not require anything from chef or
knife. The CLI lives in `lib/chef/knife/`: one file per command, plus
`helpers/proxmox_base.rb` (cluster/token resolution, mixed into every
command) and `helpers/proxmox_vm_provision.rb` (the provisioning flag
surface shared by `vm create` and `vm bootstrap`).

Within the core: Client is pure transport and scrubs secrets before they
can reach an exception; Api is stateless single round-trips; anything
needing cross-call ordering belongs in Provisioner, whose collaborators
(ui, port_check, sleeper) are injected so specs run without sockets or
sleeps.

## Tests

WebMock blocks all network access. spec_helper deliberately does not
eager-load `lib/`; each spec requires only its own subject. Keep new specs
that way.

## Releasing

Bump `Knife::Proxmox::VERSION` in `lib/knife-proxmox-ve/version.rb` and
merge to main. CI (release.yml) builds, tags, and publishes to rubygems
via Trusted Publishing. Never create version tags manually; the version
file is the single source of truth. CHANGELOG.md is intentionally unused
(GitHub Releases auto-generates notes).

## Etiquette

Branches `feature/…`, `bugfix/…`, `fix/…`, `change/…`, merged to main via
PR. Commit subjects: short imperative, no conventional-commit prefixes.
