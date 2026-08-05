# frozen_string_literal: true

require "ferrum"
require "json"
require "net/http"

module Erep
  class Browser
    # Owns the Chrome OS process and its CDP endpoint: attaching to a live
    # instance, launching a fresh one, seeding Cloudflare clearance (phase 1),
    # and tearing everything down. Knows nothing about the game — it only hands
    # back a connected Ferrum::Browser.
    class ChromeProcess
      CHROME_BIN = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
      CHROME_PROFILE_DIR = File.expand_path("../../../tmp/chrome-profile", __dir__)
      CDP_PORT = 9232
      # Max wait for a single CDP command. A deploy POST can take >30s when the
      # game server is slow; at 30s Ferrum raised send_message timeout mid-deploy
      # and killed the whole fight session (see winning-side deploy, battle 924445).
      CDP_TIMEOUT = 60

      def initialize(log:)
        @log = log
        @pid = nil
        Dir.mkdir(CHROME_PROFILE_DIR) unless Dir.exist?(CHROME_PROFILE_DIR)
      end

      # Reuse a Chrome already listening on the CDP port. Returns a connected
      # Ferrum::Browser or nil when nothing usable is running.
      def attach
        return nil unless cdp_port_alive?
        return nil if chrome_pids.empty?

        @pid = nil # we did not spawn this one
        browser = ferrum
        close_extra_tabs
        browser
      rescue StandardError => e
        log "Failed to attach to existing Chrome: #{e.message}"
        nil
      end

      # Phase 2: spawn Chrome with remote debugging and connect Ferrum via CDP.
      def launch
        ensure_profile_unlocked
        log "Phase 2: Launching Chrome with CDP..."
        @pid = spawn(
          CHROME_BIN,
          "--remote-debugging-port=#{CDP_PORT}",
          "--remote-debugging-address=127.0.0.1",
          "--user-data-dir=#{CHROME_PROFILE_DIR}",
          "--no-first-run",
          "--no-default-browser-check",
          "--disable-blink-features=AutomationControlled",
          "--window-size=1920,1080",
          "--use-angle=metal",
          "--remote-allow-origins=*",
          err: "/dev/null", out: "/dev/null"
        )

        wait_for_cdp
        browser = ferrum
        browser.evaluate_on_new_document(<<~JS)
          Object.defineProperty(navigator, 'webdriver', { get: () => undefined });
        JS
        close_extra_tabs
        browser
      end

      # Phase 1: launch clean Chrome (no CDP) so Cloudflare Turnstile auto-solves
      # and mints a cf_clearance cookie, then tear it down.
      def seed_clearance(cloudflare)
        ensure_profile_unlocked
        cloudflare.clear!

        3.times do |attempt|
          # A spawn against a profile already owned by another Chrome silently
          # forwards the URL to that instance (opens a new tab) instead of starting
          # fresh — no challenge runs, no cookie issued. Guarantee the profile is free.
          ensure_profile_unlocked

          log "Phase 1: Seeding Cloudflare clearance (attempt #{attempt + 1}/3)..."
          seed_pid = spawn(
            CHROME_BIN,
            "--user-data-dir=#{CHROME_PROFILE_DIR}",
            "--no-first-run",
            "--no-default-browser-check",
            "--window-size=1920,1080",
            "--use-angle=metal",
            "#{BASE_URL}/en",
            err: "/dev/null", out: "/dev/null"
          )

          clearance_found = cloudflare.poll(timeout: 30)

          # SIGTERM on the launcher PID leaves Chrome helpers alive holding the
          # profile; kill everything bound to the profile dir. Kill first, then
          # reap — otherwise we deadlock when Turnstile never auto-solves.
          kill_stale_chrome
          Process.wait(seed_pid) rescue nil

          if clearance_found
            log "Phase 1 done — cf_clearance obtained"
            return
          end

          log "Phase 1 attempt #{attempt + 1} failed — no cf_clearance cookie"
          sleep 3
        end

        log "WARNING: cf_clearance not confirmed after 3 attempts, proceeding anyway"
      end

      def kill!
        if @pid
          Process.kill("TERM", @pid) rescue nil
          Process.wait(@pid) rescue nil
        else
          chrome_pids.each { |pid| Process.kill("TERM", pid.to_i) rescue nil }
        end
      end

      # Chrome treats the profile dir as a singleton: a second launch with the same
      # --user-data-dir forwards its URL to the running instance (new tab) and exits.
      # Kill any owner and clear the SingletonLock symlink before spawning.
      def ensure_profile_unlocked
        kill_stale_chrome

        singleton = File.join(CHROME_PROFILE_DIR, "SingletonLock")
        File.unlink(singleton) if File.symlink?(singleton) || File.exist?(singleton)
      rescue Errno::ENOENT
        # Already gone — fine
      end

      def kill_stale_chrome
        pids = chrome_pids.uniq
        return if pids.empty?

        log "Killing #{pids.size} stale Chrome process(es)"
        pids.each { |pid| Process.kill("KILL", pid.to_i) rescue nil }

        # Wait until port is actually free — Chrome forwards launches to existing
        # instances by --user-data-dir, so a new launch will silently attach to a
        # surviving process unless we confirm the port is released.
        20.times do
          break if `lsof -ti:#{CDP_PORT} 2>/dev/null`.strip.empty? && chrome_pids.empty?
          sleep 0.25
        end
      end

      private

      def ferrum
        Ferrum::Browser.new(url: "http://127.0.0.1:#{CDP_PORT}", timeout: CDP_TIMEOUT)
      end

      def cdp_port_alive?
        Net::HTTP.get_response(URI("http://127.0.0.1:#{CDP_PORT}/json/version")).is_a?(Net::HTTPSuccess)
      rescue StandardError
        false
      end

      def close_extra_tabs
        targets = JSON.parse(Net::HTTP.get(URI("http://127.0.0.1:#{CDP_PORT}/json/list")))
        pages = targets.select { |t| t["type"] == "page" }
        return if pages.size <= 1

        pages[1..].each do |target|
          Net::HTTP.get(URI("http://127.0.0.1:#{CDP_PORT}/json/close/#{target['id']}")) rescue nil
        end

        targets.select { |t| t["type"] == "page" && t["url"] == "chrome://newtab/" }.each do |target|
          Net::HTTP.get(URI("http://127.0.0.1:#{CDP_PORT}/json/close/#{target['id']}")) rescue nil
        end
      end

      def chrome_pids
        from_port = `lsof -ti:#{CDP_PORT} 2>/dev/null`.strip.split("\n")
        from_profile = `pgrep -f "user-data-dir=#{CHROME_PROFILE_DIR}" 2>/dev/null`.strip.split("\n")
        (from_port + from_profile).reject(&:empty?)
      end

      def wait_for_cdp
        20.times do
          Net::HTTP.get(URI("http://127.0.0.1:#{CDP_PORT}/json/version"))
          return
        rescue Errno::ECONNREFUSED
          sleep 0.5
        end
        raise "Chrome CDP not available on port #{CDP_PORT} after 10s"
      end

      def log(msg)
        @log.call(msg)
      end
    end
  end
end
