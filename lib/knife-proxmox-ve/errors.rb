# frozen_string_literal: true

module Knife
  module Proxmox
    # Base class for every error raised by the Proxmox layer. Rescue this to catch all.
    class Error < StandardError; end

    # Transport-level failure: DNS, refused connection, TLS verification failure, timeout
    # at the socket level (as opposed to an HTTP error response from Proxmox).
    class ConnectionError < Error; end

    # A non-2xx HTTP response from the Proxmox API.
    #
    # +body+ is pre-scrubbed of secret-bearing keys (token secret, cipassword, sshkeys,
    # password) by the client before the error is constructed, so it is safe to display.
    class ApiError < Error
      attr_reader :status, :body

      def initialize(message, status:, body: nil)
        @status = status
        @body = body
        super(message)
      end
    end

    # 401/403. The message carries a hint about Proxmox API-token privilege separation,
    # the most common first-run cause (the token has no rights until ACLs are granted).
    class AuthError < ApiError; end

    # 404 — resource (node, VM, task) not found at the requested path.
    class NotFoundError < ApiError; end

    # A Proxmox async task (clone, start, ...) finished with exitstatus != "OK".
    #
    # +log+ is pre-scrubbed of secret-bearing keys, so it is safe to display.
    class TaskError < Error
      attr_reader :upid, :exitstatus, :log

      def initialize(message, upid:, exitstatus:, log: nil)
        @upid = upid
        @exitstatus = exitstatus
        @log = log
        super(message)
      end
    end

    # A polling deadline (task completion, boot/IP discovery) was exceeded.
    class TimeoutError < Error; end
  end
end
