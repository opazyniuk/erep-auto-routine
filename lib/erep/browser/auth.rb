# frozen_string_literal: true

module Erep
  class Browser
    # Logs in, reusing a live session when the persistent profile already carries
    # one, and re-seeding Cloudflare clearance when the form is blocked.
    class Auth
      def initialize(session)
        @session = session
      end

      def login(email, password)
        email_field = attempt_login_page

        unless email_field
          # cf_clearance was stale despite valid expiry — re-seed and retry
          log "Cloudflare challenge detected, re-seeding clearance..."
          @session.reseed_clearance!
          log "Browser ready (retry)"
          email_field = attempt_login_page

          unless email_field
            save_screenshot("login_form_missing")
            raise LoginError, "Login form not found — blocked by Cloudflare even after re-seed"
          end
        end

        return true if email_field == :logged_in

        log "Filling credentials..."
        email_field.focus.type(email)
        @session.at_css("#citizen_password").focus.type(password)
        @session.at_css("#login_form button[type='submit']").click

        @session.network.wait_for_idle(timeout: 10)
        sleep 3

        if @session.current_url.include?("/login")
          save_screenshot("login_failed")
          raise LoginError, "Login failed — check credentials"
        end

        log "Logged in successfully"
        true
      end

      private

      # Returns the email field element, :logged_in, or nil (Cloudflare blocked).
      def attempt_login_page
        log "Navigating to login page..."
        @session.go_to("#{BASE_URL}/en")
        sleep 3

        dump_login_state("initial")

        if @session.logged_in?
          log "Already logged in via session"
          return :logged_in
        end

        # CF interstitial often takes 10-60s to self-resolve; don't bail on it.
        # Only give up once it persists past the resolve timeout.
        cf_resolve_timeout = 25
        login_wait_timeout = 15
        deadline = Time.now + cf_resolve_timeout
        logged_cf_wait = false

        log "Waiting for login form..."
        attempt = 0
        while Time.now < deadline
          sleep 3
          return :logged_in if @session.logged_in?

          email_field = @session.at_css("#citizen_email")
          return email_field if email_field

          if @session.cloudflare_challenge?
            unless logged_cf_wait
              log "Cloudflare interstitial detected — waiting for self-resolve..."
              logged_cf_wait = true
            end
            next
          end

          attempt += 1
          log "Login form not ready, waiting... (attempt #{attempt})"
          dump_login_state("retry_#{attempt}") if attempt == 3
          break if attempt * 3 >= login_wait_timeout
        end

        dump_login_state("timeout")
        nil
      end

      def dump_login_state(label)
        snapshot = @session.evaluate(<<~JS) rescue nil
          (function() {
            var visible = function(sel) {
              var els = document.querySelectorAll(sel);
              var count = 0;
              for (var i = 0; i < els.length; i++) {
                var s = window.getComputedStyle(els[i]);
                if (s.display !== 'none' && s.visibility !== 'hidden' && els[i].offsetParent !== null) count++;
              }
              return { total: els.length, visible: count };
            };
            return {
              url: location.href,
              title: document.title,
              citizen_email: !!document.querySelector('#citizen_email'),
              login_form: visible('#login_form, form[action*="login"]'),
              logout_markers: visible('#logout, .logout, [href*="logout"]'),
              has_serverdata: typeof window.SERVER_DATA !== 'undefined',
              has_citizenid_json: document.body.innerHTML.indexOf('"citizenId"') !== -1
            };
          })()
        JS
        log "DOM state [#{label}]: #{snapshot.to_json}"
      rescue StandardError => e
        log "dump_login_state[#{label}] failed: #{e.message}"
      end

      def log(msg)
        @session.log(msg)
      end

      def save_screenshot(name)
        @session.save_screenshot(name)
      end
    end
  end
end
