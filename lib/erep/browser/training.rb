# frozen_string_literal: true

require "json"

module Erep
  class Browser
    # Trains the default grounds via the training API and, at month's end, buys
    # the Pro Training Contract from the gold shop.
    class Training
      def initialize(session)
        @session = session
      end

      def train
        log "Checking training status via API..."
        @session.ensure_on_main_page

        token = @session.csrf_token
        raise TrainError, "Could not extract CSRF token" unless token

        @session.evaluate(<<~JS)
          (async () => {
            try {
              var tgResp = await fetch('/en/main/training-grounds-json', { credentials: 'same-origin' });
              var tgData = await tgResp.json();

              var items = Array.isArray(tgData) ? tgData : Object.values(tgData.grounds || tgData);
              var grounds = items.filter(function(g) { return g.default && !g.trained; })
                                 .map(function(g) { return g.id || g.building_id; });

              if (grounds.length === 0) {
                window.__trainResult = JSON.stringify({status: 'already_trained', message: 'All grounds already trained'});
                return;
              }

              var formData = new URLSearchParams();
              formData.append('_token', '#{token}');
              grounds.forEach(function(id, i) {
                formData.append('grounds[' + i + '][id]', id);
                formData.append('grounds[' + i + '][train]', '1');
              });

              var trainResp = await fetch('/en/economy/train', {
                method: 'POST',
                credentials: 'same-origin',
                headers: {'Content-Type': 'application/x-www-form-urlencoded'},
                body: formData.toString()
              });
              window.__trainResult = JSON.stringify(await trainResp.json());
            } catch(e) {
              window.__trainResult = JSON.stringify({status: 'error', message: e.message});
            }
          })()
        JS

        sleep 3
        result_json = @session.evaluate("window.__trainResult") rescue nil
        log "Train result: #{result_json}"

        result = JSON.parse(result_json) rescue {}
        api_confirmed = result["result"] || result["status"] == "already_trained"
        raise TrainError, "Train API did not confirm success: #{result_json}" unless api_confirmed

        if (r = result["result"])
          log "Trained! +#{r['strength_bonus']} strength, +#{r['xp']} XP, +#{r['gold']} gold"
        end

        begin
          verify_training_complete
        rescue StandardError => e
          log "Training verification failed (non-fatal, API confirmed success): #{e.message}"
          save_screenshot("train_verify_error")
        end

        :success
      rescue StandardError => e
        log "Training failed: #{e.message}"
        save_screenshot("train_error")
        raise
      end

      def buy_pro_training_contract
        log "Checking Pro Training Contract availability..."
        @session.ensure_on_main_page

        @session.go_to("#{BASE_URL}/en/main/gold-items")
        sleep 5

        available = @session.evaluate(<<~JS)
          (function() {
            var el = document.querySelector("#TrainingContract2");
            if (!el) return "not_found";
            if (el.classList.contains("frozen")) return "frozen";
            var soldOut = el.querySelector("[ng-if='pack.soldOut']");
            if (soldOut && soldOut.offsetParent !== null) return "sold_out";
            var buyBtn = el.querySelector("a[ng-click*=popupTriggerGold]");
            if (!buyBtn) return "no_button";
            return "available";
          })()
        JS

        unless available == "available"
          log "Pro Training Contract not available: #{available}"
          return :unavailable
        end

        @session.evaluate('document.querySelector("#TrainingContract2 a[ng-click*=popupTriggerGold]").click()')
        sleep 3

        purchase_btn = @session.at_css("a.purchaseBtn") rescue nil
        unless purchase_btn
          log "Purchase popup did not appear"
          save_screenshot("pro_training_no_popup")
          return :error
        end

        purchase_btn.click
        sleep 3

        status = @session.evaluate(<<~JS)
          (function() {
            var el = document.querySelector("#TrainingContract2");
            if (!el) return "unknown";
            if (el.classList.contains("frozen")) return "purchased";
            var soldOut = el.querySelector("[ng-if='pack.soldOut']");
            if (soldOut) return "purchased";
            var buyBtn = el.querySelector("a[ng-click*=popupTriggerGold]");
            if (!buyBtn) return "purchased";
            return "still_available";
          })()
        JS

        if status == "purchased"
          log "Pro Training Contract purchased successfully"
          :success
        else
          log "Pro Training Contract purchase uncertain: #{status}"
          :uncertain
        end
      rescue StandardError => e
        log "Pro Training Contract purchase failed: #{e.message}"
        save_screenshot("pro_training_error")
        :failure
      end

      private

      def verify_training_complete
        log "Verifying training on UI..."
        @session.go_to("#{BASE_URL}/en/economy/training-grounds")
        sleep 3

        verified = @session.evaluate(<<~JS)
          (function() {
            var trainBtn = document.querySelector('#train_btn, .train_btn, button.train, [class*="train_button"]');
            if (trainBtn && trainBtn.offsetParent !== null) return 'train_button_visible';

            var grounds = document.querySelectorAll('.training_ground, .groundDetails, [class*="training_ground"]');
            var allTrained = true;
            grounds.forEach(function(g) {
              var hasGreen = g.querySelector('.trained, .status_trained, .green_check, [class*="trained"]');
              if (!hasGreen) allTrained = false;
            });

            return allTrained ? 'verified' : 'unverified';
          })()
        JS

        log "Training verification: #{verified}"
        raise TrainError, "Training grounds still show train button — training may have failed" if verified == "train_button_visible"

        verified == "verified"
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
