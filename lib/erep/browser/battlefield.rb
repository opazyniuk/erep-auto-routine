# frozen_string_literal: true

require "json"

module Erep
  class Browser
    # Read-only battlefield and account intelligence: campaigns, battle scores,
    # wall state, round fighters, fuel/energy balances and the Infantry Kit gate.
    class Battlefield
      def initialize(session)
        @session = session
      end

      def battle_zone_active?(zone_id)
        active = @session.evaluate(<<~JS)
          (function() {
            var sd = typeof SERVER_DATA !== 'undefined' ? SERVER_DATA : null;
            if (!sd || !sd.zoneId) return null;
            if (sd.battleZoneId && sd.battleZoneId.toString() === '#{zone_id}') {
              return !sd.division_end && !sd.zoneFinished;
            }
            var ended = document.querySelector('.battle_ended, .round_ended, [class*="finished"]');
            return !ended;
          })()
        JS
        active != false
      end

      def read_battle_score
        score = @session.evaluate(<<~JS)
          (function() {
            var leftPtsEl = document.querySelector('.campaignPointsTextLeft');
            var rightPtsEl = document.querySelector('.campaignPointsTextRight');
            if (!leftPtsEl || !rightPtsEl) return null;
            var leftPts = parseInt(leftPtsEl.textContent.trim(), 10);
            var rightPts = parseInt(rightPtsEl.textContent.trim(), 10);
            if (isNaN(leftPts) || isNaN(rightPts)) return null;

            var leftSide = document.querySelector('.domination .country.left_side');
            var rightSide = document.querySelector('.domination .country.right_side');
            var leftDefender = !!(leftSide && leftSide.querySelector('img[src*="shield"]'));
            var rightDefender = !!(rightSide && rightSide.querySelector('img[src*="shield"]'));

            var defenderPoints, invaderPoints;
            if (leftDefender && !rightDefender) {
              defenderPoints = leftPts; invaderPoints = rightPts;
            } else if (rightDefender && !leftDefender) {
              defenderPoints = rightPts; invaderPoints = leftPts;
            } else {
              return null;
            }
            return JSON.stringify({defender_points: defenderPoints, invader_points: invaderPoints});
          })()
        JS
        return nil unless score

        JSON.parse(score, symbolize_names: true)
      rescue StandardError
        nil
      end

      def read_wall_state
        wall = @session.evaluate(<<~JS)
          (function() {
            var sd = typeof SERVER_DATA !== 'undefined' ? SERVER_DATA : null;
            if (sd && sd.wallDomination !== undefined) {
              return JSON.stringify({
                left_country: sd.leftSideCountryId || sd.invaderId,
                right_country: sd.rightSideCountryId || sd.defenderId,
                left_pct: sd.wallDomination,
                right_pct: 100 - sd.wallDomination
              });
            }
            var left = document.querySelector('.war_progress_bar_left .percentage, .left_side .percentage');
            var right = document.querySelector('.war_progress_bar_right .percentage, .right_side .percentage');
            if (left && right) {
              return JSON.stringify({
                left_pct: parseFloat(left.textContent),
                right_pct: parseFloat(right.textContent)
              });
            }
            return null;
          })()
        JS
        return nil unless wall

        JSON.parse(wall, symbolize_names: true)
      rescue StandardError
        nil
      end

      def fetch_campaigns
        @session.ensure_on_main_page
        @session.evaluate(<<~JS)
          (async () => {
            try {
              var resp = await fetch('/en/military/campaignsJson/list', { credentials: 'same-origin' });
              window.__campaignsResult = JSON.stringify(await resp.json());
            } catch(e) { window.__campaignsResult = JSON.stringify({error: e.message}); }
          })()
        JS
        sleep 3
        json = @session.evaluate("window.__campaignsResult") rescue nil
        JSON.parse(json || "{}")
      end

      def fetch_battle_stats(battle_id, division, zone_id)
        token = @session.csrf_token
        @session.evaluate(<<~JS)
          (async () => {
            try {
              var formData = new URLSearchParams();
              formData.append('battleId', '#{battle_id}');
              formData.append('zoneId', '#{division}');
              formData.append('battleZoneId', '#{zone_id}');
              formData.append('action', 'battleStatistics');
              formData.append('round', '0');
              formData.append('division', '#{division}');
              formData.append('type', 'damage');
              formData.append('leftPage', '0');
              formData.append('rightPage', '0');
              formData.append('_token', '#{token}');
              var resp = await fetch('/en/military/battle-console', {
                method: 'POST',
                credentials: 'same-origin',
                headers: {'Content-Type': 'application/x-www-form-urlencoded'},
                body: formData.toString()
              });
              window.__battleStatsResult = JSON.stringify(await resp.json());
            } catch(e) { window.__battleStatsResult = JSON.stringify({error: e.message}); }
          })()
        JS
        sleep 2
        json = @session.evaluate("window.__battleStatsResult") rescue nil
        JSON.parse(json || "{}")
      end

      # Returns [{side_country_id:, name:, damage:, citizen_id:, citizenship_*}, ...]
      def analyze_round_fighters(battle_id, zone_id)
        stats = fetch_battle_stats(battle_id, 3, zone_id)

        fighters = []
        stats.each do |key, side_data|
          next if key == "rounds"
          next unless side_data.is_a?(Hash)

          fighter_data = side_data["fighterData"]
          next unless fighter_data.is_a?(Hash)

          fighter_data.each_value do |f|
            fighters << {
              side_country_id: key.to_i,
              citizen_id: f["citizenId"],
              name: f["citizenName"],
              damage: (f["raw_value"] || f["damage"]).to_i,
              citizenship_permalink: f["country_permalink"],
              citizenship_name: f["country_name"]
            }
          end
        end

        if fighters.any?
          fighters.each { |f| log "Side #{f[:side_country_id]}: #{f[:name]} (#{f[:citizenship_permalink]}, damage=#{f[:damage]})" }
        else
          log "Round empty, proceeding"
        end

        fighters
      end

      def fetch_account_info
        @session.ensure_on_main_page
        info = @session.evaluate(<<~JS)
          (function() {
            var sd = typeof SERVER_DATA !== 'undefined' ? SERVER_DATA : null;
            if (!sd && typeof erepublik !== 'undefined') sd = erepublik.settings;
            if (!sd) return null;
            return JSON.stringify({
              citizenId: sd.citizenId,
              division: sd.division,
              level: sd.level || sd.citizenLevel,
              xp: sd.xp || sd.citizenXp,
              health: sd.health || sd.energy,
              csrfToken: sd.csrfToken
            });
          })()
        JS
        return nil unless info

        JSON.parse(info)
      end

      def infantry_kit_active?
        log "Checking Infantry Kit status..."
        @session.ensure_on_main_page
        citizen_id = @session.citizen_id

        unless citizen_id
          log "Could not read citizen ID — assuming Infantry Kit NOT active"
          save_screenshot("citizen_id_missing")
          return false
        end

        @session.go_to("#{BASE_URL}/en/citizen/profile/#{citizen_id}")
        sleep 3

        result = @session.evaluate(<<~JS)
          (function() {
            var selectors = [
              'span.no_xp_fight',
              '.no_xp_fight',
              '[data-booster*="infantry_kit"]',
              '[class*="infantry_kit"]',
              '[class*="infantryKit"]'
            ];
            for (var i = 0; i < selectors.length; i++) {
              if (document.querySelector(selectors[i])) {
                return { active: true, matched: selectors[i] };
              }
            }
            var html = document.body.innerHTML.toLowerCase();
            if (html.indexOf('no_xp_fight') !== -1 || html.indexOf('infantry kit') !== -1) {
              return { active: true, matched: 'text-match' };
            }
            return { active: false, matched: null };
          })()
        JS

        active = result && result["active"]
        if active
          log "Infantry Kit: ACTIVE (matched #{result['matched']})"
        else
          log "Infantry Kit: NOT ACTIVE (no marker found on profile)"
          save_screenshot("infantry_kit_missing")
        end
        active
      end

      def read_fuel_balance
        @session.go_to("#{BASE_URL}/en/military/campaigns")
        sleep 3

        fuel = @session.evaluate(<<~JS)
          (function() {
            var left = document.querySelector('#fuelLeft');
            var max = document.querySelector('#maxFuel');
            if (!left || !max) return null;
            return JSON.stringify({
              left: parseInt(left.textContent.trim()),
              max: parseInt(max.textContent.trim())
            });
          })()
        JS
        return nil unless fuel

        result = JSON.parse(fuel)
        log "Fuel: #{result['left']}/#{result['max']}"
        { left: result["left"], max: result["max"] }
      end

      def read_energy
        energy = @session.evaluate(<<~JS)
          (function() {
            var current = document.querySelector('#currentEnergy');
            var limit = document.querySelector('#energyLimit');
            if (!current || !limit) return null;
            return JSON.stringify({
              current: parseInt(current.textContent.trim()),
              limit: parseInt(limit.textContent.trim())
            });
          })()
        JS
        return nil unless energy

        JSON.parse(energy, symbolize_names: true)
      end

      # Live round lifecycle read from the battlefield page, used to skip a round
      # we can't deploy into (deploy POST into a resolved/transitioning zone returns
      # "Battle zone unavailable"). Only two fields are trustworthy here:
      #   zoneStarted  — false between rounds (the transition window where deploys fail)
      #   battleFinished — the whole battle is over
      # We deliberately do NOT use #battle_countdown: measured twice 6s apart it counts
      # UP and equals zoneElapsedTime, i.e. it's elapsed round time, not remaining —
      # useless as an "about to close" signal. Nor battle_close_to_finish: it stayed 0
      # on a round with only 3:32 elapsed-to-cap, so it tracks the campaign nearing a
      # decision, not the round. Returns {started:, finished:} or nil without SERVER_DATA.
      def round_state
        state = @session.evaluate(<<~JS)
          (function() {
            var sd = (typeof SERVER_DATA !== 'undefined') ? SERVER_DATA : null;
            if (!sd) return null;
            return JSON.stringify({
              started: sd.zoneStarted === true,
              finished: sd.battleFinished == 1
            });
          })()
        JS
        return nil unless state

        JSON.parse(state, symbolize_names: true)
      rescue StandardError
        nil
      end

      private

      def log(msg)
        @session.log(msg)
      end

      def save_screenshot(name)
        @session.save_screenshot(name)
      end
    end
  end
end
