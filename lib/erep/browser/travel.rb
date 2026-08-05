# frozen_string_literal: true

require "json"

module Erep
  class Browser
    # Travels the citizen back to their residence after a fight session.
    class Travel
      def initialize(session)
        @session = session
      end

      def travel_home
        log "Traveling back to home location..."
        @session.ensure_on_main_page

        location_info = @session.evaluate(<<~JS)
          (function() {
            var btn = document.querySelector('a.travelToResidence, a.erpkLaunchTravelPopButton');
            if (!btn) return null;
            var name = btn.querySelector('.name');
            var title = btn.getAttribute('title') || '';
            return JSON.stringify({ name: name ? name.textContent.trim() : '', title: title });
          })()
        JS

        unless location_info
          log "No travel-to-residence button found"
          return :already_home
        end

        info = JSON.parse(location_info)
        log "Current location: #{info["name"]} (#{info["title"]})"

        if at_home?
          log "Already at home location"
          return :already_home
        end

        @session.evaluate(<<~JS)
          document.querySelector('a.travelToResidence, a.erpkLaunchTravelPopButton').click()
        JS
        log "Travel popup opened"
        sleep 5

        moved = @session.evaluate(<<~JS)
          (function() {
            var moveBtn = document.querySelector('#travel_move');
            if (!moveBtn) return 'no_move_button';
            if (moveBtn.classList.contains('disabled')) return 'disabled';
            moveBtn.click();
            return 'moved';
          })()
        JS

        if moved == "moved"
          log "Moved to home location"
          sleep 3
          :success
        else
          log "Move button not available: #{moved}"
          :failure
        end
      rescue StandardError => e
        log "Travel home failed: #{e.message}"
        :failure
      end

      private

      def at_home?
        @session.evaluate(<<~JS)
          (function() {
            var btn = document.querySelector('a.travelToResidence');
            if (!btn) return true;
            if (btn.classList.contains('atResidence') || btn.classList.contains('home')) return true;
            return false;
          })()
        JS
      end

      def log(msg)
        @session.log(msg)
      end
    end
  end
end
