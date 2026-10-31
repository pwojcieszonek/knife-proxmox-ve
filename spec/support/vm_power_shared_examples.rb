# frozen_string_literal: true

# Behaviour shared by the VM power commands (`vm start` / `vm stop` / `vm shutdown`).
# The including spec defines subject(:command) targeting "web-01" and passes the Api
# message (+action+), the status the action leads to (+desired+) and the status the VM
# starts from (+initial+). api_timeout: true mirrors ProxmoxVmPower — the --timeout value
# is then expected in the Api action call itself, and wait_task gets TASK_WAIT_GRACE more.
RSpec.shared_examples "a vm power command" do |action:, desired:, initial:, api_timeout: false|
  let(:api) { instance_double(Knife::Proxmox::Api) }
  let(:upid) { "UPID:pve1:00001234:00ABCDEF:00000000:qm#{action}:101:knife@pve!automation:" }
  let(:vm) { { vmid: 101, node: "pve1", name: "web-01", status: initial } }
  let(:grace) { api_timeout ? Chef::Knife::ProxmoxVmPower::TASK_WAIT_GRACE : 0 }

  before do
    SharedConfig.install!
    # Fold mixlib-cli option defaults (--timeout 300) into config, as knife's real run
    # path does via #configure_chef. Without it config[:timeout] is nil and the command
    # fatals — which exits the whole rspec process, silently truncating the suite.
    command.merge_configs
    allow(command).to receive(:proxmox_api).and_return(api)
    allow(api).to receive(:find_vm).with("web-01").and_return(vm)
    allow(api).to receive(:vm_status).with(node: "pve1", vmid: 101).and_return(initial)
    allow(api).to receive(:wait_status).and_return(true)
    allow(api).to receive(action).and_return(upid)
    allow(api).to receive(:wait_task).and_return(true)
    # Silence terminal output (msg_pair goes through ui.info).
    allow(command.ui).to receive(:info)
    allow(command.ui).to receive(:warn)
  end

  describe "#run" do
    it "fires #{action} against the resolved VM's node and vmid" do
      command.run

      expected = { node: "pve1", vmid: 101 }
      expected[:timeout] = 300 if api_timeout
      expect(api).to have_received(action).with(**expected)
    end

    it "waits for the #{action} task with the default 300s timeout" do
      command.run

      expect(api).to have_received(:wait_task).with(upid:, timeout: 300 + grace)
    end

    it "coerces a --timeout CLI override (String) to Integer" do
      command.config[:timeout] = "60"

      command.run

      expect(api).to have_received(:wait_task).with(upid:, timeout: 60 + grace)
      expect(api).to have_received(action).with(hash_including(timeout: 60)) if api_timeout
    end

    it "waits for the VM to reach #{desired} after the task, within the same deadline" do
      command.run

      expect(api).to have_received(:wait_task).ordered
      expect(api).to have_received(:wait_status)
        .with(node: "pve1", vmid: 101, status: desired, timeout: a_value_between(0, 300 + grace))
        .ordered
    end

    it "fails without reporting success when the VM never reaches #{desired}" do
      allow(api).to receive(:wait_status)
        .and_raise(Knife::Proxmox::TimeoutError, "VM 101 did not reach #{desired} within 300s")
      allow(command).to receive(:msg_pair)

      expect { command.run }.to raise_error(Knife::Proxmox::TimeoutError)
      expect(command).not_to have_received(:msg_pair)
    end

    it "decides on the live status, not the cluster-cached one" do
      vm[:status] = desired

      command.run

      expect(api).to have_received(action)
    end

    it "warns and skips the API action when the VM is already #{desired}" do
      allow(api).to receive(:vm_status).with(node: "pve1", vmid: 101).and_return(desired)

      command.run

      expect(api).not_to have_received(action)
      expect(api).not_to have_received(:wait_task)
      expect(command.ui).to have_received(:warn).with(/already #{desired}/)
    end

    it "reports the VM identity and the new status" do
      allow(command).to receive(:msg_pair)

      command.run

      expect(command).to have_received(:msg_pair).with("VM name", "web-01")
      expect(command).to have_received(:msg_pair).with("VMID", 101)
      expect(command).to have_received(:msg_pair).with("Node", "pve1")
      expect(command).to have_received(:msg_pair).with("Status", desired)
    end

    it "errors, shows usage and exits without a target argument" do
      command.name_args = []
      allow(command.ui).to receive(:error)
      allow(command).to receive(:show_usage)

      expect { command.run }.to raise_error(SystemExit)
      expect(command.ui).to have_received(:error).with(/exactly one VM NAME_OR_VMID/)
      expect(command).to have_received(:show_usage)
    end

    it "errors, shows usage and exits with more than one target argument" do
      command.name_args = %w{web-01 web-02}
      allow(command.ui).to receive(:error)
      allow(command).to receive(:show_usage)

      expect { command.run }.to raise_error(SystemExit)
      expect(api).not_to have_received(action)
    end

    it "propagates a NotFoundError from VM resolution" do
      allow(api).to receive(:find_vm)
        .and_raise(Knife::Proxmox::NotFoundError.new("no qemu VM matches", status: 404))

      expect { command.run }.to raise_error(Knife::Proxmox::NotFoundError)
      expect(api).not_to have_received(action)
    end

    it "fatals on a non-integer --timeout before touching the task" do
      command.config[:timeout] = "soon"
      allow(command.ui).to receive(:fatal!).and_raise(SystemExit)

      expect { command.run }.to raise_error(SystemExit)
      expect(api).not_to have_received(:wait_task)
    end
  end

  describe "command wiring" do
    it "declares --timeout with a 300s default" do
      expect(described_class.options[:timeout][:long]).to eq("--timeout SECONDS")
      expect(described_class.options[:timeout][:default]).to eq(300)
    end

    it "mixes in ProxmoxBase and ProxmoxVmPower" do
      expect(described_class.ancestors)
        .to include(Chef::Knife::ProxmoxBase, Chef::Knife::ProxmoxVmPower)
    end
  end
end
