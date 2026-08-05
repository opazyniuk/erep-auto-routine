# frozen_string_literal: true

module Erep
  class Browser
    # Claims daily-mission and weekly-challenge rewards from the home page.
    class Challenges
      def initialize(session)
        @session = session
      end

      def collect_daily_challenge
        log "Collecting daily challenge rewards..."
        @session.go_to("#{BASE_URL}/en")
        sleep 3

        @session.evaluate("document.querySelector('#dailyMissionsPopupTrigger').click()")
        sleep 3

        objectives_claimed = @session.evaluate(<<~JS)
          (function() {
            var items = document.querySelectorAll('.rewardWrapper.unclaimed');
            var count = 0;
            for (var i = 0; i < items.length; i++) {
              items[i].click();
              count++;
            }
            return count;
          })()
        JS
        sleep 2 if objectives_claimed.to_i > 0

        missions_claimed = 0
        10.times do
          clicked = @session.evaluate(<<~JS)
            (function() {
              var btns = document.querySelectorAll('a.claimButton');
              for (var i = 0; i < btns.length; i++) {
                var btn = btns[i];
                if (!btn.classList.contains('disabled') && btn.offsetParent !== null) {
                  btn.click();
                  return 1;
                }
              }
              return 0;
            })()
          JS
          break if clicked == 0
          missions_claimed += 1
          sleep 1
        end

        log "Daily challenge: #{objectives_claimed} objective(s), #{missions_claimed} mission(s) claimed"
        { objectives: objectives_claimed, missions: missions_claimed }
      end

      def collect_weekly_challenge
        log "Collecting weekly challenge rewards..."
        @session.go_to("#{BASE_URL}/en")
        sleep 3

        clicked = @session.evaluate(<<~JS)
          (function() {
            var btn = document.querySelector('a[ng-click="getAllReward()"]');
            if (!btn || btn.offsetParent === null) return 'no_button';
            btn.click();
            return 'clicked';
          })()
        JS

        if clicked == "no_button"
          log "No weekly rewards to collect"
          return :nothing_to_collect
        end

        sleep 2
        log "Weekly challenge: collected all rewards"
        :success
      end

      private

      def log(msg)
        @session.log(msg)
      end
    end
  end
end
