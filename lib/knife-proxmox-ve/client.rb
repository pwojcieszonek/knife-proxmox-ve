# frozen_string_literal: true

require "net/http" unless defined?(Net::HTTP)
require "json" unless defined?(JSON)
require "openssl" unless defined?(OpenSSL)
require "uri" unless defined?(URI)
require "cgi" unless defined?(CGI)
require "erb" unless defined?(ERB)

require "knife-proxmox-ve/errors"

module Knife
  module Proxmox
    # Thin net/http wrapper over the Proxmox VE REST API. Pure transport: it knows
    # nothing about VMs, tasks or knife. It signs every request with a PVEAPIToken,
    # unwraps the Proxmox "data" envelope, maps non-2xx responses onto the error tree
    # and scrubs secrets out of anything that reaches an exception.
    class Client
      BASE_PATH = "/api2/json"

      # Transport-level exceptions that mean "we never got a valid HTTP reply".
      TRANSPORT_ERRORS = [
        SocketError,
        OpenSSL::SSL::SSLError,
        Errno::ECONNREFUSED,
        Net::OpenTimeout,
        Net::ReadTimeout,
      ].freeze

      # Response keys whose VALUES carry secrets and must be redacted before any body or task
      # log is surfaced in an exception. Proxmox echoes submitted params in error bodies and
      # task logs. (The token secret is redacted separately, by literal-value substitution in
      # #scrub, since it never appears under a key name in a body.)
      SECRET_KEYS = %w{cipassword password sshkeys}.freeze

      FILTERED = "[FILTERED]"

      # URL-encode a single path segment so reserved characters survive intact when the
      # caller assembles a path (":" -> %3A, "/" -> %2F). Proxmox VMIDs, UPIDs and node
      # names land in path segments, and UPIDs contain colons.
      def self.encode_segment(value)
        ERB::Util.url_encode(value.to_s)
      end

      def initialize(host:, token_id:, token_secret:, port: 8006, verify_ssl: true)
        @host = host
        @port = port
        @token_id = token_id
        @token_secret = token_secret
        @verify_ssl = verify_ssl
      end

      # GET +path+ with non-secret +query+ params appended to the URL query string.
      def get(path, query = {})
        uri = build_uri(path)
        uri.query = URI.encode_www_form(query) unless query.empty?
        request(Net::HTTP::Get.new(uri))
      end

      # POST +path+ with a form-encoded body (application/x-www-form-urlencoded).
      def post(path, body = {})
        send_with_body(Net::HTTP::Post, path, body)
      end

      # Redact secret-bearing values from arbitrary text (e.g. a Proxmox task log, which is
      # returned with HTTP 200 and so does not pass through the error-body scrub path).
      def scrub_text(str)
        scrub(str)
      end

      private

      def send_with_body(verb_class, path, body)
        req = verb_class.new(build_uri(path))
        req.set_form_data(body) unless body.empty?
        request(req)
      end

      def build_uri(path)
        URI::HTTPS.build(host: @host, port: @port, path: "#{BASE_PATH}#{path}")
      end

      def request(req)
        req["Authorization"] = "PVEAPIToken=#{@token_id}=#{@token_secret}"
        req["Accept"] = "application/json"

        response = transport.request(req)
        handle(response)
      rescue *TRANSPORT_ERRORS => e
        raise ConnectionError, "connection to #{@host}:#{@port} failed: #{e.class}: #{scrub(e.message)}"
      end

      def transport
        http = Net::HTTP.new(@host, @port)
        http.use_ssl = true
        http.verify_mode = @verify_ssl ? OpenSSL::SSL::VERIFY_PEER : OpenSSL::SSL::VERIFY_NONE
        http
      end

      def handle(response)
        status = response.code.to_i
        return unwrap(response.body) if status.between?(200, 299)

        raise_for(status, response.body)
      end

      def unwrap(body)
        return nil if body.nil? || body.empty?

        JSON.parse(body)["data"]
      end

      def raise_for(status, body)
        case status
        when 401, 403
          raise AuthError.new(
            "authentication failed (HTTP #{status}); check the token has privileges " \
            "(Proxmox API tokens default to privilege separation)",
            status:, body: scrub(body)
          )
        when 404
          raise NotFoundError.new("not found (HTTP 404)", status:, body: scrub(body))
        else
          raise ApiError.new("Proxmox API error (HTTP #{status})", status:, body: scrub(body))
        end
      end

      # Redact the token secret literal and the values of secret-bearing keys before a
      # response body is allowed into an exception message/attribute.
      def scrub(str)
        return str if str.nil? || str.empty?

        scrubbed = str.gsub(@token_secret, FILTERED)
        SECRET_KEYS.each do |key|
          scrubbed = redact_key(scrubbed, key)
        end
        scrubbed
      end

      # Redact +key+'s value across the three shapes Proxmox surfaces: form-encoded
      # (key=value), JSON ("key":"value"), and the CLI/space-delimited form task logs use
      # (-key value), since clone/config task logs echo applied params.
      def redact_key(str, key)
        k = Regexp.escape(key)
        str
          .gsub(/(#{k}=)[^&\s"]*/, "\\1#{FILTERED}")
          .gsub(/("#{k}"\s*:\s*)"[^"]*"/, "\\1\"#{FILTERED}\"")
          .gsub(/(-#{k}[=\s]+)\S+/, "\\1#{FILTERED}")
      end
    end
  end
end
