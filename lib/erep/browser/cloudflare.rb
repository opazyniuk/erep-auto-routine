# frozen_string_literal: true

module Erep
  class Browser
    # Reads and manages the cf_clearance cookie in Chrome's SQLite cookie store.
    # Turnstile mints the cookie during the phase-1 seed; this class tells the
    # seeder whether one is present and still valid.
    class Cloudflare
      def initialize(profile_dir:)
        @profile_dir = profile_dir
      end

      def poll(timeout: 30)
        (timeout / 2).times do
          sleep 2
          return true if valid?
        end
        false
      end

      def valid?
        db = cookies_db
        return false unless db

        output = `sqlite3 "#{db}" "SELECT expires_utc FROM cookies WHERE name='cf_clearance' AND host_key LIKE '%erepublik%' LIMIT 1" 2>/dev/null`.strip
        return false if output.empty?

        # Chrome stores expires_utc as microseconds since 1601-01-01; shift to the
        # Unix epoch by subtracting 11_644_473_600 seconds.
        expires_unix = (output.to_i / 1_000_000) - 11_644_473_600
        expires_unix > Time.now.to_i
      rescue StandardError
        false
      end

      def clear!
        db = cookies_db
        return unless db

        `sqlite3 "#{db}" "DELETE FROM cookies WHERE name='cf_clearance' AND host_key LIKE '%erepublik%'" 2>/dev/null`
      end

      private

      def cookies_db
        [
          File.join(@profile_dir, "Default", "Network", "Cookies"),
          File.join(@profile_dir, "Default", "Cookies")
        ].find { |f| File.exist?(f) }
      end
    end
  end
end
