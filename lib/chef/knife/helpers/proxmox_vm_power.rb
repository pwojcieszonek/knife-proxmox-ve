# frozen_string_literal: true

class Chef
  class Knife
    # Shared flow for the VM power commands (`vm start` / `vm stop` / `vm shutdown`):
    # resolve the target VM by name or vmid, short-circuit when it is already in the
    # desired state, fire the status endpoint, then wait for the async task and for the VM
    # to reach that state. Commands stay declarative: banner plus a one-line #run naming
    # the action.
    module ProxmoxVmPower
      # Extra seconds the client waits beyond an endpoint-side timeout, so the PVE task
      # reports its own failure (e.g. a guest ignoring ACPI) before the client deadline
      # expires and masks it with a generic TimeoutError.
      TASK_WAIT_GRACE = 15

      def self.included(includer)
        includer.class_eval do
          option :timeout,
            long:        "--timeout SECONDS",
            description: "Seconds to wait for the power task (default 300).",
            default:     300
        end
      end

      private

      # +action+ is the Api message (:start / :stop / :shutdown); +desired+ the VM status
      # the action leads to ("running" / "stopped"). A VM already in the desired state is
      # a warning and a clean exit, not an API error — so the command is safe to re-run.
      # With api_timeout: true the --timeout value is also sent to the endpoint itself
      # (shutdown: bounds the ACPI wait inside the PVE task, which is otherwise unbounded),
      # and the client wait is extended by TASK_WAIT_GRACE.
      #
      # Success means the VM reached +desired+, not just that the task finished: for an
      # HA-managed VM the task only queues the request, so the live status is polled after
      # it, within what is left of the same deadline.
      def power_action!(action, desired:, api_timeout: false)
        vm = resolve_power_target!(action)
        target = { node: vm[:node], vmid: vm[:vmid] }

        # find_vm's status is cluster-cached and can lag a recent power change.
        if proxmox_api.vm_status(**target) == desired
          ui.warn("VM #{vm[:name]} (vmid #{vm[:vmid]}) is already #{desired}")
          return
        end

        timeout = power_timeout
        if api_timeout
          api_params = { timeout: }
          wait_timeout = timeout + TASK_WAIT_GRACE
        else
          api_params = {}
          wait_timeout = timeout
        end
        deadline = monotonic_now + wait_timeout

        upid = proxmox_api.public_send(action, **target, **api_params)
        proxmox_api.wait_task(upid:, timeout: wait_timeout)
        remaining = [deadline - monotonic_now, 0].max
        proxmox_api.wait_status(**target, status: desired, timeout: remaining)

        msg_pair("VM name", vm[:name])
        msg_pair("VMID", vm[:vmid])
        msg_pair("Node", vm[:node])
        msg_pair("Status", desired)
      end

      def resolve_power_target!(action)
        unless name_args.length == 1
          ui.error("knife proxmox vm #{action} takes exactly one VM NAME_OR_VMID")
          show_usage
          exit 1
        end

        proxmox_api.find_vm(name_args.first)
      end

      # A CLI override arrives as a String; wait_task's deadline arithmetic needs an
      # Integer.
      def power_timeout
        value = config[:timeout]
        int = Integer(value.to_s, 10)
        ui.fatal!("--timeout must be greater than 0 (got #{int})") unless int > 0
        int
      rescue ArgumentError
        ui.fatal!("--timeout must be an integer (got #{value.inspect})")
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
