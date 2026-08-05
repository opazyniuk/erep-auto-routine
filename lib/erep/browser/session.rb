# frozen_string_literal: true

require "forwardable"
require "fileutils"
require_relative "../logger"
require_relative "chrome_process"
require_relative "cloudflare"

module Erep
  class Browser
    # The live page: wraps the Ferrum handle, exposes the primitives the domain
    # services build on (evaluate/go_to/at_css/mouse/...), and owns the page-state
    # predicates, screenshots and logging shared across every service.
    class Session
      extend Forwardable

      def_delegators :@browser, :evaluate, :go_to, :body, :current_url, :at_css, :mouse, :network, :screenshot
      def_delegators :@logger, :log

      attr_reader :browser

      def initialize(log_file: nil)
        @logger = Logger.new(log_file, indent: "   ")
        @chrome = ChromeProcess.new(log: method(:log))
        @cloudflare = Cloudflare.new(profile_dir: ChromeProcess::CHROME_PROFILE_DIR)
        connect
      end

      # Drop stale cf_clearance, re-seed via clean Chrome, and relaunch under CDP.
      # Used by the login flow when Cloudflare blocks the form despite a live session.
      def reseed_clearance!
        @browser.quit rescue nil
        @chrome.seed_clearance(@cloudflare)
        @browser = @chrome.launch
      end

      # Drops the Ferrum CDP connection but leaves Chrome running so the next run
      # can reattach with the live session (cf_clearance + login cookies intact).
      def quit
        @browser.quit rescue nil
      end

      def kill!
        @browser.quit rescue nil
        @chrome.kill!
      end

      def logged_in?
        evaluate(<<~JS) rescue false
          (function() {
            // Primary signal: erepublik bootstraps a SERVER_DATA global with citizenId on logged-in pages
            if (typeof window.SERVER_DATA === 'object' && window.SERVER_DATA &&
                (window.SERVER_DATA.citizenId || (window.SERVER_DATA.citizen && window.SERVER_DATA.citizen.citizenId))) {
              return true;
            }

            var isVisible = function(el) {
              if (!el) return false;
              var s = window.getComputedStyle(el);
              return s.display !== 'none' && s.visibility !== 'hidden' && el.offsetParent !== null;
            };
            var positives = document.querySelectorAll('#logout, .logout, [href*="logout"]');
            for (var i = 0; i < positives.length; i++) {
              if (isVisible(positives[i])) return true;
            }

            if (document.body.innerHTML.indexOf('"citizenId"') !== -1) return true;
            return false;
          })()
        JS
      end

      def citizen_id
        evaluate(<<~JS) rescue nil
          (function() {
            var sd = typeof SERVER_DATA !== 'undefined' ? SERVER_DATA : null;
            if (!sd && typeof erepublik !== 'undefined') sd = erepublik.settings;
            if (sd) {
              if (sd.citizenId) return sd.citizenId;
              if (sd.citizen_id) return sd.citizen_id;
              if (sd.citizen && sd.citizen.citizenId) return sd.citizen.citizenId;
              if (sd.citizen && sd.citizen.id) return sd.citizen.id;
              if (sd.user && sd.user.citizenId) return sd.user.citizenId;
            }

            var links = document.querySelectorAll('a[href*="/citizen/profile/"]');
            for (var i = 0; i < links.length; i++) {
              var m = links[i].getAttribute('href').match(/\\/citizen\\/profile\\/(\\d+)/);
              if (m) return parseInt(m[1], 10);
            }

            var m2 = document.body.innerHTML.match(/"citizenId"\\s*:\\s*(\\d+)/);
            if (m2) return parseInt(m2[1], 10);
            return null;
          })()
        JS
      end

      def cloudflare_challenge?
        evaluate(<<~JS) rescue false
          (function() {
            if (document.querySelector('iframe[src*="challenges.cloudflare"]')) return true;
            if (document.querySelector('#challenge-running, #challenge-stage')) return true;
            var title = document.title.toLowerCase();
            var markers = ['just a moment', 'attention required', 'зачекайте'];
            for (var i = 0; i < markers.length; i++) {
              if (title.indexOf(markers[i]) !== -1) return true;
            }
            return false;
          })()
        JS
      end

      def csrf_token
        source = body
        match = source.match(/var\s+csrfToken\s*=\s*'(\w{32})'/) ||
                source.match(/name="_token"\s+value="(\w{32})"/)
        match&.[](1)
      end

      def ensure_on_main_page
        return if current_url.start_with?("#{BASE_URL}/en") &&
                  !current_url.include?("/login") &&
                  logged_in?

        go_to("#{BASE_URL}/en")
        sleep 3
      end

      def save_screenshot(name)
        dir = File.expand_path("../../../log", __dir__)
        FileUtils.mkdir_p(dir)
        path = File.join(dir, "#{name}.png")
        screenshot(path: path)
        log "Screenshot saved: #{path}"
      end

      private

      def connect
        if (@browser = @chrome.attach)
          log "Browser ready (reused existing Chrome on CDP port #{ChromeProcess::CDP_PORT})"
        else
          @chrome.kill_stale_chrome
          @browser = @chrome.launch
          log "Browser ready"
        end
      end
    end
  end
end
