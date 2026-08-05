# frozen_string_literal: true

module Erep
  class Browser
    # Activates the fight boosters: the smallest-duration 50% damage booster and
    # the shadow (catch-up) booster, skipping any already running.
    class Boosters
      def initialize(session)
        @session = session
      end

      def ensure_damage_booster
        if damage_active?
          log "50% damage booster already active"
          return :already_active
        end

        log "Activating 50% damage booster..."
        open_booster_list

        activated = activate_smallest_damage_booster
        if activated.to_s.start_with?("clicked")
          sleep 1
          confirm_damage_activation
          sleep 2
          activated = "activated: " + activated.sub("clicked: ", "")
        end
        sleep 2

        if activated.to_s.start_with?("activated")
          log "50% damage booster #{activated}"
        else
          log "Could not activate damage booster: #{activated}"
        end

        ensure_shadow_booster
        :success
      end

      private

      def damage_active?
        @session.evaluate(<<~JS)
          (function() {
            var booster = document.querySelector('.activeBoosters.damage');
            if (!booster) return false;
            return booster.querySelector('.boosterTimer') !== null;
          })()
        JS
      end

      def open_booster_list
        @session.evaluate(<<~JS)
          (function() {
            var btn = document.querySelector('#db_list_go');
            if (btn && !btn.classList.contains('disabled')) btn.click();
          })()
        JS
        sleep 2
      end

      # 50% damage boosters carry class "damage_q5"; pick the shortest duration.
      def activate_smallest_damage_booster
        @session.evaluate(<<~JS)
          (function() {
            var items = document.querySelectorAll('li.damage_q5');
            if (items.length === 0) return 'no_50pct_boosters';

            var boosters = [];
            for (var i = 0; i < items.length; i++) {
              var li = items[i];
              var overlay = li.querySelector('.activationOverlay');
              if (!overlay || overlay.offsetParent === null) continue;

              var durEl = li.querySelector('.boosterDuration');
              var durText = durEl ? durEl.textContent.trim() : '';
              var minutes = 999999;
              var match;
              if (match = durText.match(/(\\d+)\\s*MIN/i)) minutes = parseInt(match[1]);
              else if (match = durText.match(/(\\d+)\\s*H/i)) minutes = parseInt(match[1]) * 60;

              boosters.push({minutes: minutes, overlay: overlay, text: durText});
            }

            if (boosters.length === 0) return 'no_clickable_50pct';

            boosters.sort(function(a, b) { return a.minutes - b.minutes; });
            boosters[0].overlay.click();
            return 'clicked: ' + boosters[0].text;
          })()
        JS
      end

      def confirm_damage_activation
        @session.evaluate(<<~JS)
          (function() {
            var confirm = document.querySelector('.booster_list .confirmation a, .booster_list .confirm, li.damage_q5 .confirmation a, li.damage_q5 a.confirm');
            if (confirm) { confirm.click(); return 'confirmed'; }
            var overlays = document.querySelectorAll('.activationOverlay');
            for (var i = 0; i < overlays.length; i++) {
              if (overlays[i].offsetParent !== null && overlays[i].closest('.confirmation')) {
                overlays[i].click();
                return 'confirmed_overlay';
              }
            }
            return 'no_confirm';
          })()
        JS
      end

      def ensure_shadow_booster
        if shadow_active?
          log "Shadow booster already active"
          return
        end

        # Reopen boosters list (may have closed after damage booster activation)
        @session.evaluate(<<~JS)
          (function() {
            var btn = document.querySelector('#db_list_go');
            if (btn && !btn.classList.contains('disabled') && !btn.classList.contains('opened')) btn.click();
          })()
        JS
        sleep 2

        # Shadow boosters carry class "catchup_q30" on the <li>
        activated = @session.evaluate(<<~JS)
          (function() {
            var item = document.querySelector('li.catchup_q30');
            if (!item) return 'no_shadow_boosters';
            var overlay = item.querySelector('.activationOverlay');
            if (!overlay || overlay.offsetParent === null) return 'no_clickable';
            overlay.click();
            return 'clicked';
          })()
        JS

        if activated == "clicked"
          sleep 1
          @session.evaluate(<<~JS)
            (function() {
              var confirm = document.querySelector('li.catchup_q30 .confirmation a, .booster_list .confirmation a, .booster_list .confirm');
              if (confirm) { confirm.click(); return 'confirmed'; }
              return 'no_confirm';
            })()
          JS
          sleep 2
          activated = "activated"
        end

        if activated == "activated"
          log "Shadow booster activated"
        else
          log "Could not activate shadow booster: #{activated}"
        end
      end

      def shadow_active?
        @session.evaluate(<<~JS)
          (function() {
            var booster = document.querySelector('.activeBoosters.catchup');
            if (!booster) return false;
            return booster.querySelector('.boosterTimer') !== null;
          })()
        JS
      end

      def log(msg)
        @session.log(msg)
      end
    end
  end
end
