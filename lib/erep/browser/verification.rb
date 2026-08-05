# frozen_string_literal: true

require "json"
require "base64"
require "fileutils"
require_relative "../logger"
require_relative "../captcha/solve_pipeline"
require_relative "../captcha/template_extractor"

module Erep
  class Browser
    # Detects eRepublik's session-verification captcha and resolves it, either by
    # waiting for a manual solve or by driving the automated solver pipeline.
    class Verification
      SOLVE_MODE = :user # :user = wait for manual solve, :auto = use pipeline solver
      USER_TIMEOUT = 240 # seconds to wait for the user to solve the captcha
      LOG_PATH = File.expand_path("../../../log/captcha.log", __dir__)
      CAPTCHAS_DIR = File.expand_path("../../../log/captchas", __dir__)

      def initialize(session)
        @session = session
      end

      def handle_verification
        log "Checking for account verification..."

        captcha_info = @session.evaluate(<<~JS)
          (function() {
            var sd = typeof SERVER_DATA !== 'undefined' ? SERVER_DATA : null;
            if (!sd || !sd.sessionValidation) {
              var vBox = document.querySelector('#verificationBox');
              if (vBox) return JSON.stringify({captchaId: null, remainingTime: 0, fromDom: true});
              return null;
            }
            return JSON.stringify(sd.sessionValidation);
          })()
        JS

        unless captcha_info
          log "No verification needed"
          return true
        end

        info = JSON.parse(captcha_info)
        remaining = info["remainingTime"] || 0
        captcha_id = info["captchaId"] || resolve_captcha_id_from_dom
        return false unless captcha_id

        captcha_log "Captcha required (id=#{captcha_id}, remaining=#{remaining}s), solving..."

        case SOLVE_MODE
        when :user then solve_captcha_user(captcha_id)
        when :auto then solve_captcha_auto(captcha_id)
        end
      end

      private

      # DOM-detected verification carries no captchaId; click Verify to open the
      # popup, then re-read SERVER_DATA for the freshly issued id.
      def resolve_captcha_id_from_dom
        log "Verification box detected in DOM, clicking Verify button..."
        @session.evaluate("(function(){ var btn = document.querySelector('#startSessionVerify'); if(btn) btn.click(); })()")
        sleep 3

        fresh_info = @session.evaluate(<<~JS)
          (function() {
            var sd = typeof SERVER_DATA !== 'undefined' ? SERVER_DATA : null;
            if (sd && sd.sessionValidation) return JSON.stringify(sd.sessionValidation);
            return null;
          })()
        JS
        captcha_id = fresh_info && JSON.parse(fresh_info)["captchaId"]

        unless captcha_id
          log "Could not obtain captchaId after clicking Verify"
          save_screenshot("captcha_no_id")
        end
        captcha_id
      end

      def solve_captcha_user(captcha_id)
        log "Captcha solve mode: USER — waiting for manual solve in browser..."
        save_captcha_snapshot(captcha_id)

        start = Time.now
        loop do
          elapsed = (Time.now - start).to_i
          detected = visible_verification_element

          unless detected
            log "Captcha solved by user! (took #{elapsed}s)"
            return true
          end

          if elapsed >= USER_TIMEOUT
            log "Timeout waiting for user to solve captcha (#{USER_TIMEOUT}s)"
            save_screenshot("captcha_timeout")
            return false
          end

          log "Waiting for user to solve captcha... (#{elapsed}s elapsed, detected: #{detected})" if (elapsed % 30).zero? && elapsed > 0
          sleep 5
        end
      end

      # Mere DOM presence isn't enough — after a manual solve these elements often
      # linger hidden while SERVER_DATA.sessionValidation stays stale until reload.
      # Use computed style + offsetParent for true visibility.
      def visible_verification_element
        @session.evaluate(<<~JS)
          (function() {
            function visible(el) {
              if (!el) return false;
              if (el.offsetParent === null) return false;
              var st = window.getComputedStyle(el);
              if (st.display === 'none' || st.visibility === 'hidden') return false;
              if (parseFloat(st.opacity) === 0) return false;
              var rect = el.getBoundingClientRect();
              if (rect.width === 0 || rect.height === 0) return false;
              return true;
            }
            if (visible(document.querySelector('#sessionUnlockModal'))) return 'modal';
            if (visible(document.querySelector('#verificationBox'))) return 'box';
            return null;
          })()
        JS
      end

      def solve_captcha_auto(captcha_id)
        captcha_log "Captcha solve mode: AUTO — using pipeline solver..."
        backoff = [2, 4, 8]
        3.times do |attempt|
          captcha_log "Captcha attempt #{attempt + 1}/3..."
          return true if solve_captcha(captcha_id)

          captcha_log "Attempt #{attempt + 1} failed, retrying with fresh challenge..."
          dismiss_captcha_modal
          sleep backoff[attempt]
        end
        captcha_log "All captcha attempts failed"
        false
      end

      def save_captcha_snapshot(captcha_id)
        load_captcha_challenge(captcha_id)
        img_b64 = capture_captcha_image
        return unless img_b64

        FileUtils.mkdir_p(CAPTCHAS_DIR)
        path = File.join(CAPTCHAS_DIR, "captcha_#{timestamp}_challenge.png")
        File.write(path, Base64.decode64(img_b64))
        captcha_log "Captcha challenge saved: #{path}"
      rescue StandardError => e
        captcha_log "Failed to save captcha snapshot: #{e.message}"
      end

      def solve_captcha(captcha_id)
        load_captcha_challenge(captcha_id)

        img_b64 = capture_captcha_image
        return false unless img_b64

        FileUtils.mkdir_p(CAPTCHAS_DIR)
        @captcha_archive_path = File.join(CAPTCHAS_DIR, "captcha_#{timestamp}.png")
        File.write(@captcha_archive_path, Base64.decode64(img_b64))
        captcha_log "Captcha saved: #{@captcha_archive_path}"

        min_cnt = @session.evaluate("window.__captchaData && window.__captchaData.minCnt").to_i rescue 3
        min_cnt = 3 if min_cnt < 1

        pipeline = Captcha::SolvePipeline.new(log_method: method(:captcha_log), work_dir: CAPTCHAS_DIR)
        coordinates = pipeline.solve(@captcha_archive_path, icon_count: min_cnt)

        if coordinates.empty?
          captcha_log "Pipeline could not solve captcha"
          save_screenshot("captcha_unsolved")
          return false
        end

        click_captcha_coordinates(coordinates)
        success = submit_captcha_and_verify
        archive_result(success, pipeline, coordinates)
        success
      end

      # Tag the saved image with the outcome, and on success mine the matched icons
      # into fresh templates for the matcher.
      def archive_result(success, pipeline, coordinates)
        return unless @captcha_archive_path && File.exist?(@captcha_archive_path)

        tag = success ? "solved" : "failed"
        tagged_path = @captcha_archive_path.sub(".png", "_#{tag}.png")
        File.rename(@captcha_archive_path, tagged_path)
        captcha_log "Captcha tagged: #{tagged_path}"

        return unless success && pipeline.last_split_paths

        top_gray = pipeline.last_split_paths[:top_gray]
        Captcha::TemplateExtractor.new.extract(top_gray, coordinates) if top_gray && File.exist?(top_gray)
      end

      def load_captcha_challenge(captcha_id)
        @session.evaluate(<<~JS)
          (async () => {
            var resp = await fetch('/en/main/sessionUnlockPopup', { credentials: 'same-origin' });
            var container = document.createElement('div');
            container.innerHTML = await resp.text();
            document.body.appendChild(container);

            var resp2 = await fetch('/en/main/sessionCaptcha', { credentials: 'same-origin' });
            var container2 = document.createElement('div');
            container2.innerHTML = await resp2.text();
            document.body.appendChild(container2);
          })()
        JS
        sleep 3

        token = @session.csrf_token
        @session.evaluate(<<~JS)
          (async () => {
            try {
              var cookieNames = document.cookie.split(';').map(c => c.trim().split('=')[0]).filter(n => n);
              var env = btoa(JSON.stringify({l: ["tets"], s: [], c: cookieNames, m: 0}));
              var fd = new URLSearchParams();
              fd.append('_token', '#{token}');
              fd.append('captchaId', '#{captcha_id}');
              fd.append('env', env);
              var resp = await fetch('/en/main/sessionGetChallenge', {
                method: 'POST', credentials: 'same-origin',
                headers: {'Content-Type': 'application/x-www-form-urlencoded'},
                body: fd.toString()
              });
              var data = await resp.json();
              var img = document.querySelector('#captchaImage');
              if (img && data.src) { img.src = data.src; img.classList.remove('hide'); }
              if (data.onLoad) { try { eval(data.onLoad); } catch(e) {} }
              window.__captchaData = data;
            } catch(e) { window.__captchaError = e.message; }
          })()
        JS
        sleep 3

        10.times do
          loaded = @session.evaluate(<<~JS)
            (function() {
              var img = document.querySelector('#captchaImage');
              return img && img.src && img.src.length > 100 && !img.classList.contains('hide');
            })()
          JS
          break if loaded
          sleep 1
        end
      end

      def capture_captcha_image
        img_b64 = @session.evaluate(<<~JS)
          (function() {
            var img = document.querySelector('#captchaImage');
            if (!img || !img.src) return null;
            var canvas = document.createElement('canvas');
            canvas.width = img.naturalWidth || img.width;
            canvas.height = img.naturalHeight || img.height;
            canvas.getContext('2d').drawImage(img, 0, 0);
            return canvas.toDataURL('image/png').split(',')[1];
          })()
        JS

        unless img_b64
          log "Could not capture captcha image"
          save_screenshot("captcha_no_image")
        end
        img_b64
      end

      def click_captcha_coordinates(coordinates)
        box = JSON.parse(@session.evaluate(<<~JS))
          (function() {
            var img = document.querySelector('#captchaImage');
            var rect = img.getBoundingClientRect();
            return JSON.stringify({
              left: rect.left, top: rect.top,
              width: rect.width, height: rect.height,
              naturalWidth: img.naturalWidth, naturalHeight: img.naturalHeight
            });
          })()
        JS
        captcha_log "Image box: #{box.inspect}"

        onload_info = @session.evaluate(<<~JS)
          (function() {
            var data = window.__captchaData || {};
            return JSON.stringify({
              hasOnLoad: !!data.onLoad,
              onLoadLength: data.onLoad ? data.onLoad.length : 0,
              minCnt: data.minCnt,
              keys: Object.keys(data)
            });
          })()
        JS
        captcha_log "Captcha JS state: #{onload_info}"

        scale_x = box["width"].to_f / box["naturalWidth"].to_f
        scale_y = box["height"].to_f / box["naturalHeight"].to_f

        coordinates.each_with_index do |coord, i|
          page_x = box["left"] + (coord[:x] * scale_x)
          page_y = box["top"] + (coord[:y] * scale_y)
          captcha_log "Click #{i + 1}: image(#{coord[:x]},#{coord[:y]}) → page(#{page_x.round},#{page_y.round})"
          @session.mouse.click(x: page_x, y: page_y)
          sleep 0.5
          captcha_log "After click #{i + 1} JS state: #{click_state}"
        end
        sleep 1
      end

      def click_state
        @session.evaluate(<<~JS)
          (function() {
            var dots = document.querySelectorAll('#captchaImage ~ .captcha-dot, .captcha-dot, [class*="dot"]');
            var inputs = document.querySelectorAll('input[name*="captcha"], input[name*="coord"], input[name*="click"]');
            var globalClicks = window.__captchaClicks || window.captchaClicks || null;
            return JSON.stringify({
              dotElements: dots.length,
              hiddenInputs: Array.from(inputs).map(function(i) { return {name: i.name, value: i.value}; }),
              globalClicks: globalClicks
            });
          })()
        JS
      end

      def submit_captcha_and_verify
        save_screenshot("captcha_before_verify")
        captcha_log "Clicking Verify button..."
        @session.evaluate(<<~JS)
          (function() {
            var btn = document.querySelector('#sessionUnlockSubmit');
            if (btn) { btn.classList.remove('disabled'); btn.click(); }
          })()
        JS
        sleep 5

        still_captcha = @session.evaluate(<<~JS)
          (function() {
            var modal = document.querySelector('#sessionUnlockModal');
            return modal && modal.style.display !== 'none';
          })()
        JS

        if still_captcha
          captcha_log "Captcha modal still visible — solution was wrong"
          save_screenshot("captcha_rejected")
          false
        else
          captcha_log "Captcha solved successfully!"
          true
        end
      end

      def dismiss_captcha_modal
        @session.evaluate(<<~JS)
          (function() {
            var modal = document.querySelector('#sessionUnlockModal');
            if (modal) modal.style.display = 'none';
            var containers = document.querySelectorAll('div[class*="captcha"], div[id*="captcha"]');
            containers.forEach(function(c) { c.remove(); });
          })()
        JS
      rescue StandardError
        nil
      end

      def timestamp
        Time.now.strftime("%Y%m%d_%H%M%S")
      end

      def log(msg)
        @session.log(msg)
      end

      def save_screenshot(name)
        @session.save_screenshot(name)
      end

      def captcha_log(msg)
        @session.log(msg)
        @captcha_logger ||= Logger.new(File.open(LOG_PATH, "a"), indent: "   ")
        @captcha_logger.log(msg)
      end
    end
  end
end
