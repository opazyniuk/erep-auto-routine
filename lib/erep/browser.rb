# frozen_string_literal: true

require "ferrum"
require "json"
require "net/http"
require "base64"
require "fileutils"
require_relative "captcha/solve_pipeline"

module Erep
  class Browser
    BASE_URL = "https://www.erepublik.com"

    attr_reader :browser

    CHROME_PROFILE_DIR = File.expand_path("../../tmp/chrome-profile", __dir__)
    CHROME_BIN = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    CDP_PORT = 9232

    CAPTCHA_SOLVE_MODE = :user # :user = wait for manual solve, :auto = use pipeline solver
    CAPTCHA_USER_TIMEOUT = 240 # seconds to wait for user to solve captcha
    CAPTCHA_LOG_PATH = File.expand_path("../../log/captcha.log", __dir__)

    def initialize(log_file: nil)
      @log_file = log_file
      Dir.mkdir(CHROME_PROFILE_DIR) unless Dir.exist?(CHROME_PROFILE_DIR)
      kill_stale_chrome

      # Skip Phase 1 preemptively — session cookie usually lets the page render
      # logged-in even when cf_clearance looks stale. login() retries with a
      # fresh seed only if Cloudflare actually blocks.
      launch_chrome_with_cdp
      log "Browser ready"
    end

    def login(email, password)
      email_field = attempt_login_page

      unless email_field
        # cf_clearance was stale despite valid expiry — re-seed and retry
        log "Cloudflare challenge detected, re-seeding clearance..."
        browser.quit rescue nil
        seed_cloudflare_clearance
        launch_chrome_with_cdp
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
      browser.at_css("#citizen_password").focus.type(password)
      browser.at_css("#login_form button[type='submit']").click

      browser.network.wait_for_idle(timeout: 10)
      sleep 3

      if browser.current_url.include?("/login")
        save_screenshot("login_failed")
        raise LoginError, "Login failed — check credentials"
      end

      log "Logged in successfully"
      true
    end

    def train
      log "Checking training status via API..."
      ensure_on_main_page

      token = extract_csrf_token
      raise TrainError, "Could not extract CSRF token" unless token

      browser.evaluate(<<~JS)
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
            var trainData = await trainResp.json();
            window.__trainResult = JSON.stringify(trainData);
          } catch(e) {
            window.__trainResult = JSON.stringify({status: 'error', message: e.message});
          }
        })()
      JS

      sleep 3
      result_json = browser.evaluate("window.__trainResult") rescue nil
      log "Train result: #{result_json}"

      result = JSON.parse(result_json) rescue {}
      api_confirmed = result["result"] || result["status"] == "already_trained"
      raise TrainError, "Train API did not confirm success: #{result_json}" unless api_confirmed

      if result["result"]
        r = result["result"]
        log "Trained! +#{r['strength_bonus']} strength, +#{r['xp']} XP, +#{r['gold']} gold"
      end

      begin
        verify_training_complete
      rescue => e
        log "Training verification failed (non-fatal, API confirmed success): #{e.message}"
        save_screenshot("train_verify_error")
      end

      :success
    rescue => e
      log "Training failed: #{e.message}"
      save_screenshot("train_error")
      raise
    end

    def buy_pro_training_contract
      log "Checking Pro Training Contract availability..."
      ensure_on_main_page

      browser.go_to("#{BASE_URL}/en/main/gold-items")
      sleep 5

      # Check if Pro Training Contract is available (not sold out)
      available = browser.evaluate(<<~JS)
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

      # Click the buy button to open confirmation popup
      browser.evaluate('document.querySelector("#TrainingContract2 a[ng-click*=popupTriggerGold]").click()')
      sleep 3

      # Click Purchase in the popup
      purchase_btn = browser.at_css("a.purchaseBtn") rescue nil
      unless purchase_btn
        log "Purchase popup did not appear"
        save_screenshot("pro_training_no_popup")
        return :error
      end

      purchase_btn.click
      sleep 3

      # Verify purchase — item should now be sold out or frozen
      status = browser.evaluate(<<~JS)
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
    rescue => e
      log "Pro Training Contract purchase failed: #{e.message}"
      save_screenshot("pro_training_error")
      :failure
    end

    def collect_vip_points
      log "Collecting VIP points..."
      ensure_on_main_page

      browser.go_to("#{BASE_URL}/en/main/vip-shop")
      sleep 4

      # Verify we're on the VIP shop (not redirected)
      unless browser.current_url.include?("vip-shop")
        log "VIP shop redirected to #{browser.current_url} — skipping"
        return
      end

      state = browser.evaluate(<<~JS)
        (function() {
          var btn = document.getElementById('claimDailyVIPPoints');
          var claimed = document.getElementById('vip_claimed');
          if (!btn) return 'missing';
          var claimedVisible = claimed && claimed.offsetParent !== null;
          var btnVisible = btn.offsetParent !== null;
          if (claimedVisible || !btnVisible) return 'already';
          btn.click();
          return 'clicked';
        })()
      JS

      case state
      when "missing"
        log "VIP claim: button #claimDailyVIPPoints not found"
        save_screenshot("vip_missing")
        return :failure
      when "already"
        log "VIP points already claimed today"
        return :already_claimed
      end

      sleep 3
      verified = browser.evaluate(<<~JS)
        (function() {
          var btn = document.getElementById('claimDailyVIPPoints');
          var claimed = document.getElementById('vip_claimed');
          var claimedVisible = claimed && claimed.offsetParent !== null;
          var btnVisible = btn && btn.offsetParent !== null;
          return claimedVisible || !btnVisible;
        })()
      JS

      unless verified
        log "VIP claim: clicked but not verified (button still visible)"
        save_screenshot("vip_unverified")
        return :failure
      end

      log "VIP points collected"
      :success
    rescue => e
      log "VIP collection failed: #{e.message}"
      save_screenshot("vip_error")
      :failure
    end

    GOLD_CURRENCY_ID = 62
    DAILY_GOLD_TARGET = 10.0

    # Buy up to `amount` gold from the monetary market using available CC.
    # Walks offers cheapest-first and partial-fills if CC can't cover the full target.
    def buy_gold(amount: DAILY_GOLD_TARGET)
      log "Buying up to #{amount} gold from monetary market..."
      ensure_on_main_page

      token = extract_csrf_token
      raise TrainError, "Could not extract CSRF token for buy_gold" unless token

      browser.evaluate(<<~JS)
        (async () => {
          const log = [];
          try {
            const retrieveBody = new URLSearchParams({
              _token: '#{token}',
              personalOffers: '0',
              page: '0',
              currencyId: '#{GOLD_CURRENCY_ID}'
            });
            const retrieveResp = await fetch('/en/economy/exchange/retrieve/', {
              method: 'POST',
              credentials: 'same-origin',
              headers: {
                'Content-Type': 'application/x-www-form-urlencoded',
                'X-Requested-With': 'XMLHttpRequest'
              },
              body: retrieveBody.toString()
            });
            const retrieveData = await retrieveResp.json();
            const initialCc = parseFloat((retrieveData.ecash || {}).value || 0);
            const initialGold = parseFloat((retrieveData.gold || {}).value || 0);

            const html = retrieveData.buy_mode || '';
            const re = /id='purchase_(\\d+)' data-i18n='Buy for' data-currency='GOLD' data-price='(\\d+(?:\\.\\d+)?)' data-max='(\\d+(?:\\.\\d+)?)' trigger='purchase'/g;
            const offers = [];
            let m;
            while ((m = re.exec(html)) !== null) {
              offers.push({ offer_id: parseInt(m[1]), price: parseFloat(m[2]), amount: parseFloat(m[3]) });
            }
            offers.sort((a, b) => a.price - b.price);

            if (offers.length === 0) {
              window.__buyGoldResult = JSON.stringify({ status: 'no_offers', cc: initialCc, gold: initialGold });
              return;
            }

            let remaining = #{amount};
            let myCc = initialCc;
            let myGold = initialGold;
            const purchases = [];

            for (const o of offers) {
              if (remaining <= 0.001) break;
              const affordable = myCc / o.price;
              const take = Math.min(remaining, o.amount, affordable);
              if (take < 0.01) continue;

              const buyBody = new URLSearchParams({
                _token: '#{token}',
                amount: take.toFixed(4),
                currencyId: '#{GOLD_CURRENCY_ID}',
                offerId: o.offer_id.toString()
              });
              const buyResp = await fetch('/en/economy/exchange/purchase/', {
                method: 'POST',
                credentials: 'same-origin',
                headers: {
                  'Content-Type': 'application/x-www-form-urlencoded',
                  'X-Requested-With': 'XMLHttpRequest'
                },
                body: buyBody.toString()
              });
              const buyData = await buyResp.json();

              if (buyData.error) {
                const msg = (buyData.message || '').toString().toLowerCase();
                const code = (buyData.code || '').toString().toLowerCase();
                const isFatal = msg.includes('not_enough_money') ||
                                msg.includes('not enough money') ||
                                msg.includes('insufficient') ||
                                code.includes('not_enough_money');
                purchases.push({ offer_id: o.offer_id, price: o.price, requested: take, error: buyData.message || 'unknown', fatal: isFatal });
                if (isFatal) break;
                continue;
              }

              myCc = parseFloat((buyData.ecash || {}).value || myCc);
              myGold = parseFloat((buyData.gold || {}).value || myGold);
              purchases.push({ offer_id: o.offer_id, price: o.price, gold: take, cost: +(take * o.price).toFixed(4) });
              remaining -= take;
            }

            window.__buyGoldResult = JSON.stringify({
              status: 'done',
              target: #{amount},
              bought: +((#{amount} - remaining).toFixed(4)),
              unfilled: +remaining.toFixed(4),
              cc_before: initialCc,
              cc_after: myCc,
              gold_before: initialGold,
              gold_after: myGold,
              purchases: purchases
            });
          } catch (e) {
            window.__buyGoldResult = JSON.stringify({ status: 'error', message: e.message });
          }
        })()
      JS

      sleep 5
      result_json = browser.evaluate("window.__buyGoldResult") rescue nil
      result = JSON.parse(result_json || "{}") rescue {}

      summary = {
        status: result["status"],
        bought: result["bought"],
        unfilled: result["unfilled"],
        cc_delta: (result["cc_before"] && result["cc_after"]) ? (result["cc_before"] - result["cc_after"]).round(4) : nil,
        gold_delta: (result["gold_before"] && result["gold_after"]) ? (result["gold_after"] - result["gold_before"]).round(4) : nil
      }
      log "Buy gold result: #{summary.compact.to_json}"

      case result["status"]
      when "done"
        bought = result["bought"].to_f
        if bought >= amount - 0.01
          log "Bought #{bought} gold for #{(result['cc_before'] - result['cc_after']).round(2)} CC (gold: #{result['gold_before']} → #{result['gold_after']})"
          :success
        elsif bought > 0
          log "Partial: #{bought}/#{amount} gold bought; #{result['unfilled']} unfilled (CC exhausted or no more affordable offers)"
          :partial
        else
          log "No purchases made — likely insufficient CC for cheapest offer"
          :skipped
        end
      when "no_offers"
        log "No gold offers on monetary market"
        :no_offers
      else
        log "Buy gold error: #{result['message'] || result_json}"
        :error
      end
    rescue => e
      log "Buy gold failed: #{e.message}"
      save_screenshot("buy_gold_error")
      :failure
    end

    WEEKLY_ENERGY_BAR_PACKS = %w[energy_bars double_energy_bars].freeze

    def purchase_weekly_energy_bars
      log "Weekly energy bar purchase..."
      ensure_on_main_page

      browser.go_to("#{BASE_URL}/en/main/vip-shop")
      sleep 4

      unless browser.current_url.include?("vip-shop")
        log "VIP shop redirected to #{browser.current_url} — skipping weekly purchases"
        return :failure
      end

      results = WEEKLY_ENERGY_BAR_PACKS.map { |id| [id, purchase_vip_pack(id)] }
      results.each { |id, status| log "  #{id}: #{status}" }

      statuses = results.map(&:last)
      return :success if statuses.all? { |s| s == :purchased || s == :already_purchased }

      :partial
    rescue => e
      log "Weekly energy bar purchase failed: #{e.message}"
      save_screenshot("weekly_purchase_error")
      :failure
    end

    private def purchase_vip_pack(pack_id)
      state = browser.evaluate(<<~JS)
        (function() {
          var pack = document.getElementById(#{pack_id.to_json});
          if (!pack) return 'missing';
          var btn = pack.querySelector('.buttons a[ng-click^="popupTriggerGold"]');
          if (!btn || btn.offsetParent === null) return 'unavailable';
          if (btn.classList.contains('disabled')) return 'disabled';
          btn.click();
          return 'clicked';
        })()
      JS

      return :already_purchased if state == "unavailable"
      return :missing if state == "missing"
      return :disabled if state == "disabled"

      sleep 3
      confirm = browser.evaluate(<<~JS)
        (function() {
          var popup = document.getElementById('specialItemsPopupContainer');
          if (!popup) return 'no_popup';
          var btn = popup.querySelector('.purchaseBtn');
          if (!btn) return 'no_btn';

          function fire(el, type) {
            el.dispatchEvent(new MouseEvent(type, {bubbles:true, cancelable:true, view:window}));
          }
          function click(el) { ['mousedown','mouseup','click'].forEach(function(t){ fire(el, t); }); }

          var max = popup.querySelector('.incrementMax');
          if (max && !max.classList.contains('disabled')) {
            click(max);
          } else {
            var inc = popup.querySelector('.incrementAmount');
            for (var i = 0; i < 50 && inc && !inc.classList.contains('disabled'); i++) {
              click(inc);
            }
          }

          if (btn.classList.contains('disabled')) {
            var cancel = popup.querySelector('.cancelBtn');
            if (cancel) fire(cancel, 'click');
            return 'insufficient_gold';
          }
          click(btn);
          return 'confirmed';
        })()
      JS

      unless confirm == "confirmed"
        save_screenshot("vip_purchase_#{pack_id}_#{confirm}")
        return confirm.to_sym
      end

      verified = false
      10.times do
        sleep 1
        verified = browser.evaluate(<<~JS)
          (function() {
            var popup = document.getElementById('specialItemsPopupContainer');
            if (popup && popup.offsetParent !== null) return false;
            var pack = document.getElementById(#{pack_id.to_json});
            if (!pack) return false;
            var btn = pack.querySelector('.buttons a[ng-click^="popupTriggerGold"]');
            return !btn || btn.offsetParent === null;
          })()
        JS
        break if verified
      end

      unless verified
        save_screenshot("vip_purchase_#{pack_id}_unverified")
        return :unverified
      end

      :purchased
    end

    def go_to(url)
      browser.go_to(url)
    end

    # ── Fight API ──────────────────────────────────────────────────

    def ensure_damage_booster
      # Check if 50% damage booster is already active
      active = browser.evaluate(<<~JS)
        (function() {
          var booster = document.querySelector('.activeBoosters.damage');
          if (!booster) return false;
          var timer = booster.querySelector('.boosterTimer');
          return timer !== null;
        })()
      JS

      if active
        log "50% damage booster already active"
        return :already_active
      end

      log "Activating 50% damage booster..."

      # Open boosters list
      browser.evaluate(<<~JS)
        (function() {
          var btn = document.querySelector('#db_list_go');
          if (btn && !btn.classList.contains('disabled')) btn.click();
        })()
      JS
      sleep 2

      # Find and activate the smallest duration 50% damage booster
      # 50% damage boosters have class "damage_q5" on the <li>
      activated = browser.evaluate(<<~JS)
        (function() {
          var items = document.querySelectorAll('li.damage_q5');
          if (items.length === 0) return 'no_50pct_boosters';

          // Parse duration from each booster and sort ascending
          var boosters = [];
          for (var i = 0; i < items.length; i++) {
            var li = items[i];
            var overlay = li.querySelector('.activationOverlay');
            if (!overlay || overlay.offsetParent === null) continue;

            var durEl = li.querySelector('.boosterDuration');
            var durText = durEl ? durEl.textContent.trim() : '';
            // Parse duration to minutes for sorting
            var minutes = 999999;
            var match;
            if (match = durText.match(/(\\d+)\\s*MIN/i)) minutes = parseInt(match[1]);
            else if (match = durText.match(/(\\d+)\\s*H/i)) minutes = parseInt(match[1]) * 60;

            boosters.push({minutes: minutes, overlay: overlay, text: durText});
          }

          if (boosters.length === 0) return 'no_clickable_50pct';

          // Sort by duration ascending (smallest first)
          boosters.sort(function(a, b) { return a.minutes - b.minutes; });

          boosters[0].overlay.click();
          return 'clicked: ' + boosters[0].text;
        })()
      JS

      if activated.to_s.start_with?("clicked")
        sleep 1
        # Click the confirmation button that appears after selecting a booster
        browser.evaluate(<<~JS)
          (function() {
            var confirm = document.querySelector('.booster_list .confirmation a, .booster_list .confirm, li.damage_q5 .confirmation a, li.damage_q5 a.confirm');
            if (confirm) { confirm.click(); return 'confirmed'; }
            // Try any visible confirmation overlay
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
        sleep 2
        activated = "activated: " + activated.sub("clicked: ", "")
      end
      sleep 2

      if activated.to_s.start_with?("activated")
        log "50% damage booster #{activated}"
      else
        log "Could not activate damage booster: #{activated}"
      end

      # Also activate shadow (catchup) booster if not already active
      ensure_shadow_booster

      :success
    end

    def ensure_shadow_booster
      active = browser.evaluate(<<~JS)
        (function() {
          var booster = document.querySelector('.activeBoosters.catchup');
          if (!booster) return false;
          var timer = booster.querySelector('.boosterTimer');
          return timer !== null;
        })()
      JS

      if active
        log "Shadow booster already active"
        return
      end

      # Reopen boosters list (may have closed after damage booster activation)
      browser.evaluate(<<~JS)
        (function() {
          var btn = document.querySelector('#db_list_go');
          if (btn && !btn.classList.contains('disabled') && !btn.classList.contains('opened')) btn.click();
        })()
      JS
      sleep 2

      # Shadow boosters have class "catchup_q30" on the <li>
      activated = browser.evaluate(<<~JS)
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
        # Click the confirmation button
        browser.evaluate(<<~JS)
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

    def battle_zone_active?(zone_id)
      active = browser.evaluate(<<~JS)
        (function() {
          var sd = typeof SERVER_DATA !== 'undefined' ? SERVER_DATA : null;
          if (!sd || !sd.zoneId) return null;
          if (sd.battleZoneId && sd.battleZoneId.toString() === '#{zone_id}') {
            return !sd.division_end && !sd.zoneFinished;
          }
          // Check if the round/zone is still running from DOM
          var ended = document.querySelector('.battle_ended, .round_ended, [class*="finished"]');
          return !ended;
        })()
      JS
      active != false
    end

    def read_battle_score
      score = browser.evaluate(<<~JS)
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
    rescue
      nil
    end

    def read_wall_state
      wall = browser.evaluate(<<~JS)
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
          // Fallback: read from DOM
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
    rescue
      nil
    end

    def fetch_campaigns
      ensure_on_main_page
      browser.evaluate(<<~JS)
        (async () => {
          try {
            var resp = await fetch('/en/military/campaignsJson/list', { credentials: 'same-origin' });
            var data = await resp.json();
            window.__campaignsResult = JSON.stringify(data);
          } catch(e) { window.__campaignsResult = JSON.stringify({error: e.message}); }
        })()
      JS
      sleep 3
      json = browser.evaluate("window.__campaignsResult") rescue nil
      JSON.parse(json || "{}")
    end

    def fetch_battle_stats(battle_id, division, zone_id)
      token = extract_csrf_token
      browser.evaluate(<<~JS)
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
            var data = await resp.json();
            window.__battleStatsResult = JSON.stringify(data);
          } catch(e) { window.__battleStatsResult = JSON.stringify({error: e.message}); }
        })()
      JS
      sleep 2
      json = browser.evaluate("window.__battleStatsResult") rescue nil
      JSON.parse(json || "{}")
    end

    # Returns array of fighter hashes: [{side_country_id:, name:, damage:, citizenship:, citizen_id:}, ...]
    def analyze_round_fighters(battle_id, zone_id)
      stats = fetch_battle_stats(battle_id, 3, zone_id)

      fighters = []
      stats.each do |key, side_data|
        next if key == "rounds"
        next unless side_data.is_a?(Hash)

        fighter_data = side_data["fighterData"]
        next unless fighter_data.is_a?(Hash)

        fighter_data.each_value do |f|
          citizenship = f["citizenshipCountryId"] || f["countryId"] || f["citizenCountryId"]
          fighters << {
            side_country_id: key.to_i,
            citizen_id: f["citizenId"],
            name: f["citizenName"],
            damage: f["damage"].to_i,
            citizenship: citizenship.to_i
          }
        end
      end

      if fighters.any?
        fighters.each { |f| log "Side #{f[:side_country_id]}: #{f[:name]} (citizenship=#{f[:citizenship]}, damage=#{f[:damage]})" }
      else
        log "Round empty, proceeding"
      end

      fighters
    end

    def fetch_account_info
      ensure_on_main_page
      info = browser.evaluate(<<~JS)
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
      ensure_on_main_page
      citizen_id = browser.evaluate(<<~JS)
        (function() {
          var sd = typeof SERVER_DATA !== 'undefined' ? SERVER_DATA : null;
          if (!sd && typeof erepublik !== 'undefined') sd = erepublik.settings;
          return sd && (sd.citizenId || sd.citizen_id);
        })()
      JS

      unless citizen_id
        log "Could not read citizen ID from SERVER_DATA — assuming Infantry Kit NOT active"
        return false
      end

      browser.go_to("#{BASE_URL}/en/citizen/profile/#{citizen_id}")
      sleep 3

      active = browser.evaluate(<<~JS)
        (function() {
          var el = document.querySelector('span.no_xp_fight');
          return el !== null;
        })()
      JS

      log "Infantry Kit: #{active ? 'ACTIVE' : 'NOT ACTIVE'}"
      active
    end

    def read_fuel_balance
      browser.go_to("#{BASE_URL}/en/military/campaigns")
      sleep 3

      fuel = browser.evaluate(<<~JS)
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
      energy = browser.evaluate(<<~JS)
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

    def handle_verification
      log "Checking for account verification..."

      captcha_info = browser.evaluate(<<~JS)
        (function() {
          var sd = typeof SERVER_DATA !== 'undefined' ? SERVER_DATA : null;
          if (!sd || !sd.sessionValidation) {
            // Fallback: check for verification box in DOM
            var vBox = document.querySelector('#verificationBox');
            if (vBox) {
              // Try to extract from SERVER_DATA anyway or build minimal info
              return JSON.stringify({captchaId: null, remainingTime: 0, fromDom: true});
            }
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
      captcha_id = info["captchaId"]

      # If detected via DOM fallback without captchaId, click Verify button to get it
      if captcha_id.nil?
        log "Verification box detected in DOM, clicking Verify button..."
        browser.evaluate("(function(){ var btn = document.querySelector('#startSessionVerify'); if(btn) btn.click(); })()")
        sleep 3
        # Re-read SERVER_DATA after popup opens
        fresh_info = browser.evaluate(<<~JS)
          (function() {
            var sd = typeof SERVER_DATA !== 'undefined' ? SERVER_DATA : null;
            if (sd && sd.sessionValidation) return JSON.stringify(sd.sessionValidation);
            return null;
          })()
        JS
        if fresh_info
          info = JSON.parse(fresh_info)
          captcha_id = info["captchaId"]
        end
        unless captcha_id
          log "Could not obtain captchaId after clicking Verify"
          save_screenshot("captcha_no_id")
          return false
        end
      end

      # Always solve captcha when detected — no grace period skip

      captcha_log "Captcha required (id=#{captcha_id}, remaining=#{remaining}s), solving..."

      case CAPTCHA_SOLVE_MODE
      when :user
        solve_captcha_user(captcha_id)
      when :auto
        solve_captcha_auto(captcha_id)
      end
    end

    def solve_captcha_user(captcha_id)
      log "Captcha solve mode: USER — waiting for manual solve in browser..."

      # Save the captcha image for reference
      save_captcha_snapshot(captcha_id)

      # Poll until captcha modal disappears or timeout
      start = Time.now
      loop do
        elapsed = (Time.now - start).to_i

        # Check if verification box / modal is actually visible to the user.
        # Mere DOM presence isn't enough — after a manual solve these elements
        # often linger hidden, and SERVER_DATA.sessionValidation stays stale
        # until a reload. Use computed style + offsetParent for true visibility.
        still_needs_verification = browser.evaluate(<<~JS)
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
            var modal = document.querySelector('#sessionUnlockModal');
            if (visible(modal)) return 'modal';
            var vBox = document.querySelector('#verificationBox');
            if (visible(vBox)) return 'box';
            return null;
          })()
        JS

        unless still_needs_verification
          log "Captcha solved by user! (took #{elapsed}s)"
          return true
        end

        if elapsed >= CAPTCHA_USER_TIMEOUT
          log "Timeout waiting for user to solve captcha (#{CAPTCHA_USER_TIMEOUT}s)"
          save_screenshot("captcha_timeout")
          return false
        end

        log "Waiting for user to solve captcha... (#{elapsed}s elapsed, detected: #{still_needs_verification})" if (elapsed % 30).zero? && elapsed > 0
        sleep 5
      end
    end

    def solve_captcha_auto(captcha_id)
      captcha_log "Captcha solve mode: AUTO — using pipeline solver..."
      backoff = [2, 4, 8]
      3.times do |attempt|
        captcha_log "Captcha attempt #{attempt + 1}/3..."
        result = solve_captcha(captcha_id)
        return true if result

        captcha_log "Attempt #{attempt + 1} failed, retrying with fresh challenge..."
        dismiss_captcha_modal
        sleep backoff[attempt]
      end
      captcha_log "All captcha attempts failed"
      false
    end

    # Save captcha image without attempting to solve it
    def save_captcha_snapshot(captcha_id)
      load_captcha_challenge(captcha_id)
      img_b64 = capture_captcha_image
      return unless img_b64

      log_dir = File.expand_path("../../log/captchas", __dir__)
      FileUtils.mkdir_p(log_dir)
      stamp = Time.now.strftime("%Y%m%d_%H%M%S")
      path = File.join(log_dir, "captcha_#{stamp}_challenge.png")
      File.write(path, Base64.decode64(img_b64))
      captcha_log "Captcha challenge saved: #{path}"
    rescue => e
      captcha_log "Failed to save captcha snapshot: #{e.message}"
    end

    def solve_captcha(captcha_id)
      # Step 1: Load captcha popup and trigger challenge
      load_captcha_challenge(captcha_id)

      # Step 2: Capture captcha image
      img_b64 = capture_captcha_image
      return false unless img_b64

      log_dir = File.expand_path("../../log/captchas", __dir__)
      FileUtils.mkdir_p(log_dir)

      stamp = Time.now.strftime("%Y%m%d_%H%M%S")
      full_path = File.join(log_dir, "captcha_#{stamp}.png")
      @captcha_archive_path = full_path
      File.write(full_path, Base64.decode64(img_b64))
      captcha_log "Captcha saved: #{full_path}"

      min_cnt = browser.evaluate("window.__captchaData && window.__captchaData.minCnt") rescue 3
      min_cnt = min_cnt.to_i
      min_cnt = 3 if min_cnt < 1

      # Step 3: Solve via pipeline (LLM naming + template matching)
      pipeline = Captcha::SolvePipeline.new(log_method: method(:captcha_log), work_dir: log_dir)
      coordinates = pipeline.solve(full_path, icon_count: min_cnt)

      if coordinates.empty?
        captcha_log "Pipeline could not solve captcha"
        save_screenshot("captcha_unsolved")
        return false
      end

      # Step 4: Click coordinates on the captcha image
      click_captcha_coordinates(coordinates)

      # Step 5: Submit and verify
      success = submit_captcha_and_verify

      # Step 6: Tag archive with result and extract templates on success
      if @captcha_archive_path && File.exist?(@captcha_archive_path)
        tag = success ? "solved" : "failed"
        tagged_path = @captcha_archive_path.sub(".png", "_#{tag}.png")
        File.rename(@captcha_archive_path, tagged_path)
        captcha_log "Captcha tagged: #{tagged_path}"

        if success && pipeline.last_split_paths
          top_gray = pipeline.last_split_paths[:top_gray]
          if top_gray && File.exist?(top_gray)
            extractor = Captcha::TemplateExtractor.new
            extractor.extract(top_gray, coordinates)
          end
        end
      end

      success
    end

    def deploy(battle_id:, zone_id:, side_country_id:, weapon_quality: 7, total_energy:)
      token = extract_csrf_token
      raise FightError, "No CSRF token for deploy" unless token

      # Step 1: Get deploy inventory
      browser.evaluate(<<~JS)
        (async () => {
          try {
            var formData = new URLSearchParams();
            formData.append('_token', '#{token}');
            formData.append('battleId', '#{battle_id}');
            formData.append('sideCountryId', '#{side_country_id}');
            formData.append('battleZoneId', '#{zone_id}');
            var resp = await fetch('/en/military/fightDeploy-getInventory', {
              method: 'POST',
              credentials: 'same-origin',
              headers: {'Content-Type': 'application/x-www-form-urlencoded'},
              body: formData.toString()
            });
            var data = await resp.json();
            window.__deployInventory = JSON.stringify(data);
          } catch(e) { window.__deployInventory = JSON.stringify({error: e.message}); }
        })()
      JS
      sleep 2
      inv_json = browser.evaluate("window.__deployInventory") rescue nil
      inventory = JSON.parse(inv_json || "{}")

      if inventory["error"] == true
        log "Deploy inventory error: #{inventory.inspect}"
        return nil
      end

      # Check if deployment is disabled (already deploying or battle ended)
      if inventory["message"]
        log "Deploy unavailable: #{inventory["message"]}"
        return nil
      end

      # Check for active deployment already in progress
      if inventory["activeDeployment"]
        log "Active deployment already running (id=#{inventory["activeDeployment"]}), skipping"
        return nil
      end

      # Handle captcha if present
      if inventory["captcha"] && inventory["captcha"]["canVerifyLater"].to_i <= 0
        log "Captcha required, attempting verification..."
        handle_verification
      end

      # Check if enough energy is available (pool + recoverable)
      pool = inventory["poolEnergy"] || 0
      recoverable = inventory["recoverableEnergy"] || 0
      available = pool + recoverable
      if available < total_energy
        log "Not enough energy for deploy: available=#{available} (pool=#{pool}, recoverable=#{recoverable}), requested=#{total_energy}"
        return nil
      end

      # Validate energy bounds from server
      min_energy = inventory["minEnergy"] || 0
      max_energy = inventory["maxEnergy"] || total_energy
      unless total_energy.between?(min_energy, max_energy)
        log "Deploy energy #{total_energy} outside bounds [#{min_energy}, #{max_energy}], clamping"
        total_energy = [[total_energy, min_energy].max, max_energy].min
      end

      log "Deploy inventory OK: weapons=#{inventory["weapons"]&.size}, poolEnergy=#{inventory["poolEnergy"]}, maxEnergy=#{max_energy}"

      # Step 2: Build energy sources (pool is auto-consumed, only send food/bars)
      energy_sources = build_energy_sources(inventory, total_energy)

      # Always use q7 weapon (hardcoded preference)
      # weapon_quality param kept as-is (default 7)

      # Pick recommended or active vehicle
      vehicle = pick_vehicle(inventory)

      # Step 3: Start deploy
      energy_source_js = energy_sources.each_with_index.map { |src, i|
        "formData.append('energySources[#{i}][quality]', '#{src[:quality]}');\n" \
        "formData.append('energySources[#{i}][amount]', '#{src[:amount]}');"
      }.join("\n            ")

      browser.evaluate(<<~JS)
        (async () => {
          try {
            var formData = new URLSearchParams();
            formData.append('_token', '#{token}');
            formData.append('battleId', '#{battle_id}');
            formData.append('battleZoneId', '#{zone_id}');
            formData.append('sideCountryId', '#{side_country_id}');
            formData.append('weaponQuality', '#{weapon_quality}');
            formData.append('totalEnergy', '#{total_energy}');
            #{vehicle ? "formData.append('skinId', '#{vehicle}');" : ""}
            #{energy_source_js}

            var resp = await fetch('/en/military/fightDeploy-startDeploy', {
              method: 'POST',
              credentials: 'same-origin',
              headers: {'Content-Type': 'application/x-www-form-urlencoded'},
              body: formData.toString()
            });
            var data = await resp.json();
            window.__deployResult = JSON.stringify(data);
          } catch(e) { window.__deployResult = JSON.stringify({error: e.message}); }
        })()
      JS
      sleep 3
      result_json = browser.evaluate("window.__deployResult") rescue nil
      result = JSON.parse(result_json || "{}")

      if result["error"] == true
        log "Deploy failed: #{result["message"]}"
        return nil
      end

      deployment_id = result["deploymentId"]
      log "Deploy OK: deploymentId=#{deployment_id}, energy=#{total_energy}, fuelLeft=#{result.dig("data", "fuelLeft")}"

      # Step 4: Wait for deploy to finish, then fetch report
      if deployment_id
        sleep 3

        report = fetch_deploy_report(deployment_id)
        # Retry once if report not ready yet
        if report&.dig("error")
          sleep 3
          report = fetch_deploy_report(deployment_id)
        end

        if report && report["data"]
          data = report["data"]
          log "Deploy report: damage=#{data["damage"]}, energySpent=#{data["energySpent"]}, prestige=#{data.dig("rewards", "prestigePoints")}"
        end
      end

      result
    end

    def fetch_deploy_report(deployment_id)
      token = extract_csrf_token
      return nil unless token

      browser.evaluate(<<~JS)
        (async () => {
          try {
            var formData = new URLSearchParams();
            formData.append('_token', '#{token}');
            formData.append('deploymentId', '#{deployment_id}');
            var resp = await fetch('/en/military/fightDeploy-deployReportData', {
              method: 'POST',
              credentials: 'same-origin',
              headers: {'Content-Type': 'application/x-www-form-urlencoded'},
              body: formData.toString()
            });
            var data = await resp.json();
            window.__deployReport = JSON.stringify(data);
          } catch(e) { window.__deployReport = JSON.stringify({error: e.message}); }
        })()
      JS
      sleep 2
      json = browser.evaluate("window.__deployReport") rescue nil
      JSON.parse(json || "{}")
    end

    def switch_side(battle_id:, side_country_id:, zone_id:)
      token = extract_csrf_token
      browser.evaluate(<<~JS)
        (async () => {
          try {
            var formData = new URLSearchParams();
            formData.append('battleId', '#{battle_id}');
            formData.append('sideCountryId', '#{side_country_id}');
            formData.append('battleZoneId', '#{zone_id}');
            formData.append('_token', '#{token}');
            var resp = await fetch('/en/main/battlefieldTravel', {
              method: 'POST',
              credentials: 'same-origin',
              headers: {'Content-Type': 'application/x-www-form-urlencoded'},
              body: formData.toString()
            });
            var data = await resp.json();
            window.__switchResult = JSON.stringify(data);
          } catch(e) { window.__switchResult = JSON.stringify({error: e.message}); }
        })()
      JS
      sleep 2
      json = browser.evaluate("window.__switchResult") rescue nil
      result = JSON.parse(json || "{}")

      if result["error"] == true
        log "Switch side failed: #{result["message"]}"
      else
        log "Switched to side #{side_country_id}"
      end
      result
    end

    def collect_daily_challenge
      log "Collecting daily challenge rewards..."
      browser.go_to("#{BASE_URL}/en")
      sleep 3

      # Open the daily challenge popup
      browser.evaluate("document.querySelector('#dailyMissionsPopupTrigger').click()")
      sleep 3

      # 1. Click objective rewards (progress bar chests with class "unclaimed")
      objectives_claimed = browser.evaluate(<<~JS)
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

      # 2. Click mission Claim buttons one by one
      missions_claimed = 0
      10.times do
        clicked = browser.evaluate(<<~JS)
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
      browser.go_to("#{BASE_URL}/en")
      sleep 3

      # Click "Get all rewards" button
      clicked = browser.evaluate(<<~JS)
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

    def travel_home
      log "Traveling back to home location..."
      ensure_on_main_page

      # Check if already at home location
      location_info = browser.evaluate(<<~JS)
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
      # title is "Location: Region, Country" — if it matches the residence name, we're home
      current_location = info["name"]
      residence_hint = info["title"]
      log "Current location: #{current_location} (#{residence_hint})"

      # If the button doesn't have the travel icon state or shows we're at residence
      at_home = browser.evaluate(<<~JS)
        (function() {
          // Check if there's no travel-back indicator — user is already at residence
          var btn = document.querySelector('a.travelToResidence');
          if (!btn) return true;
          // If button has class indicating no travel needed
          if (btn.classList.contains('atResidence') || btn.classList.contains('home')) return true;
          return false;
        })()
      JS

      if at_home
        log "Already at home location"
        return :already_home
      end

      # Step 1: Click the residence travel button
      browser.evaluate(<<~JS)
        document.querySelector('a.travelToResidence, a.erpkLaunchTravelPopButton').click()
      JS
      log "Travel popup opened"
      sleep 5

      # Step 2: Click "Move to location" in the travel popup
      moved = browser.evaluate(<<~JS)
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
    rescue => e
      log "Travel home failed: #{e.message}"
      :failure
    end

    def quit
      browser.quit rescue nil
      Process.kill("TERM", @chrome_pid) rescue nil
      Process.wait(@chrome_pid) rescue nil
    end

    private

    # Returns the email field element, :logged_in, or nil (Cloudflare blocked)
    def attempt_login_page
      log "Navigating to login page..."
      browser.go_to("#{BASE_URL}/en")
      sleep 3

      dump_login_state("initial")

      if logged_in?
        log "Already logged in via session"
        return :logged_in
      end

      # Detect Cloudflare challenge early — no point waiting 30s for a login form
      if cloudflare_challenge_present?
        log "Cloudflare challenge detected immediately"
        return nil
      end

      log "Waiting for login form..."
      3.times do |i|
        sleep 5
        return :logged_in if logged_in?
        email_field = browser.at_css("#citizen_email")
        return email_field if email_field
        return nil if cloudflare_challenge_present?
        log "Login form not ready, waiting... (attempt #{i + 1}/3)"
        dump_login_state("retry_#{i + 1}") if i == 2
      end

      nil
    end

    def dump_login_state(label)
      snapshot = browser.evaluate(<<~JS) rescue nil
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
    rescue => e
      log "dump_login_state[#{label}] failed: #{e.message}"
    end

    # ── Captcha helpers ──────────────────────────────────────────

    def load_captcha_challenge(captcha_id)
      browser.evaluate(<<~JS)
        (async () => {
          var resp = await fetch('/en/main/sessionUnlockPopup', { credentials: 'same-origin' });
          var html = await resp.text();
          var container = document.createElement('div');
          container.innerHTML = html;
          document.body.appendChild(container);

          var resp2 = await fetch('/en/main/sessionCaptcha', { credentials: 'same-origin' });
          var html2 = await resp2.text();
          var container2 = document.createElement('div');
          container2.innerHTML = html2;
          document.body.appendChild(container2);
        })()
      JS
      sleep 3

      token = extract_csrf_token
      browser.evaluate(<<~JS)
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
        loaded = browser.evaluate(<<~JS)
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
      img_b64 = browser.evaluate(<<~JS)
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
      box = browser.evaluate(<<~JS)
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
      box = JSON.parse(box)
      captcha_log "Image box: #{box.inspect}"

      # Log captcha JS state before clicking
      onload_info = browser.evaluate(<<~JS)
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
        browser.mouse.click(x: page_x, y: page_y)
        sleep 0.5

        # Log what the captcha JS recorded after each click
        click_state = browser.evaluate(<<~JS)
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
        captcha_log "After click #{i + 1} JS state: #{click_state}"
      end
      sleep 1
    end

    def submit_captcha_and_verify
      save_screenshot("captcha_before_verify")
      captcha_log "Clicking Verify button..."
      browser.evaluate(<<~JS)
        (function() {
          var btn = document.querySelector('#sessionUnlockSubmit');
          if (btn) { btn.classList.remove('disabled'); btn.click(); }
        })()
      JS
      sleep 5

      still_captcha = browser.evaluate(<<~JS)
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
      browser.evaluate(<<~JS)
        (function() {
          var modal = document.querySelector('#sessionUnlockModal');
          if (modal) modal.style.display = 'none';
          var containers = document.querySelectorAll('div[class*="captcha"], div[id*="captcha"]');
          containers.forEach(function(c) { c.remove(); });
        })()
      JS
    rescue
      nil
    end

    # ── Training helpers ─────────────────────────────────────────

    def verify_training_complete
      log "Verifying training on UI..."
      browser.go_to("#{BASE_URL}/en/economy/training-grounds")
      sleep 3

      verified = browser.evaluate(<<~JS)
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

      if verified == "train_button_visible"
        raise TrainError, "Training grounds still show train button — training may have failed"
      end

      verified == "verified"
    end

    # ── Cloudflare Turnstile ────────────────────────────────────

    def seed_cloudflare_clearance
      # Ensure no Chrome is holding the profile/cookies DB, then drop any stale
      # cf_clearance so poll_cf_clearance only succeeds on a freshly minted cookie.
      ensure_profile_unlocked
      clear_cf_clearance

      3.times do |attempt|
        # A spawn against a profile that's already owned by another Chrome silently
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

        # Poll for cf_clearance cookie instead of blind sleep
        clearance_found = poll_cf_clearance(timeout: 30)

        # SIGTERM on the launcher PID leaves Chrome helper processes alive and
        # holding the profile; kill everything bound to the profile dir instead.
        # Kill first, then reap — otherwise we deadlock when Turnstile doesn't
        # auto-solve and Chrome sits on the page indefinitely.
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

    def launch_chrome_with_cdp
      ensure_profile_unlocked
      log "Phase 2: Launching Chrome with CDP..."
      @chrome_pid = spawn(
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
      @browser = Ferrum::Browser.new(url: "http://127.0.0.1:#{CDP_PORT}", timeout: 30)

      @browser.evaluate_on_new_document(<<~JS)
        Object.defineProperty(navigator, 'webdriver', { get: () => undefined });
      JS

      close_extra_tabs
    end

    def close_extra_tabs
      targets = JSON.parse(Net::HTTP.get(URI("http://127.0.0.1:#{CDP_PORT}/json/list")))
      pages = targets.select { |t| t["type"] == "page" }
      return if pages.size <= 1

      # Keep the first page, close the rest
      pages[1..].each do |target|
        Net::HTTP.get(URI("http://127.0.0.1:#{CDP_PORT}/json/close/#{target['id']}")) rescue nil
      end

      # Close extra windows by closing their blank tabs
      targets.select { |t| t["type"] == "page" && t["url"] == "chrome://newtab/" }.each do |target|
        Net::HTTP.get(URI("http://127.0.0.1:#{CDP_PORT}/json/close/#{target['id']}")) rescue nil
      end
    end

    def poll_cf_clearance(timeout: 30)
      (timeout / 2).times do
        sleep 2
        return true if cf_clearance_valid?
      end
      false
    end

    def cf_clearance_valid?
      cookies_db = find_cookies_db
      return false unless cookies_db

      # Chrome stores expires_utc as microseconds since 1601-01-01
      # Convert to Unix epoch: subtract 11644473600 seconds
      output = `sqlite3 "#{cookies_db}" "SELECT expires_utc FROM cookies WHERE name='cf_clearance' AND host_key LIKE '%erepublik%' LIMIT 1" 2>/dev/null`.strip
      return false if output.empty?

      expires_utc = output.to_i
      # Chrome epoch to Unix epoch
      expires_unix = (expires_utc / 1_000_000) - 11_644_473_600
      expires_unix > Time.now.to_i
    rescue
      false
    end

    def clear_cf_clearance
      cookies_db = find_cookies_db
      return unless cookies_db

      `sqlite3 "#{cookies_db}" "DELETE FROM cookies WHERE name='cf_clearance' AND host_key LIKE '%erepublik%'" 2>/dev/null`
    end

    def find_cookies_db
      # Chrome may store cookies in different locations
      candidates = [
        File.join(CHROME_PROFILE_DIR, "Default", "Network", "Cookies"),
        File.join(CHROME_PROFILE_DIR, "Default", "Cookies")
      ]
      candidates.find { |f| File.exist?(f) }
    end

    # ── Chrome lifecycle ─────────────────────────────────────────

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

    def chrome_pids
      from_port = `lsof -ti:#{CDP_PORT} 2>/dev/null`.strip.split("\n")
      from_profile = `pgrep -f "user-data-dir=#{CHROME_PROFILE_DIR}" 2>/dev/null`.strip.split("\n")
      (from_port + from_profile).reject(&:empty?)
    end

    def wait_for_cdp
      20.times do
        begin
          Net::HTTP.get(URI("http://127.0.0.1:#{CDP_PORT}/json/version"))
          return
        rescue Errno::ECONNREFUSED
          sleep 0.5
        end
      end
      raise "Chrome CDP not available on port #{CDP_PORT} after 10s"
    end

    def logged_in?
      browser.evaluate(<<~JS) rescue false
        (function() {
          // Primary signal: erepublik bootstraps a SERVER_DATA global with citizenId on logged-in pages
          if (typeof window.SERVER_DATA === 'object' && window.SERVER_DATA &&
              (window.SERVER_DATA.citizenId || (window.SERVER_DATA.citizen && window.SERVER_DATA.citizen.citizenId))) {
            return true;
          }

          // Secondary: presence of a *visible* logout link
          var isVisible = function(el) {
            if (!el) return false;
            var s = window.getComputedStyle(el);
            return s.display !== 'none' && s.visibility !== 'hidden' && el.offsetParent !== null;
          };
          var positives = document.querySelectorAll('#logout, .logout, [href*="logout"]');
          for (var i = 0; i < positives.length; i++) {
            if (isVisible(positives[i])) return true;
          }

          // Tertiary: SERVER_DATA blob written as inline JSON
          if (document.body.innerHTML.indexOf('"citizenId"') !== -1) return true;

          return false;
        })()
      JS
    end

    def cloudflare_challenge_present?
      browser.evaluate(<<~JS) rescue false
        (function() {
          // Turnstile iframe or Cloudflare challenge markers
          if (document.querySelector('iframe[src*="challenges.cloudflare"]')) return true;
          if (document.querySelector('#challenge-running, #challenge-stage')) return true;
          // Cloudflare "Just a moment" / "Verifying" page
          var title = document.title.toLowerCase();
          if (title.includes('just a moment') || title.includes('attention required')) return true;
          return false;
        })()
      JS
    end

    def ensure_on_main_page
      return if browser.current_url.start_with?("#{BASE_URL}/en") &&
                !browser.current_url.include?("/login") &&
                logged_in?

      browser.go_to("#{BASE_URL}/en")
      sleep 3
    end

    def build_energy_sources(inventory, total_energy)
      sources = []
      remaining = total_energy

      # Pool energy is auto-consumed by the server — just subtract from remaining
      pool_energy = (inventory["energySources"] || [])
        .select { |s| s["type"] == "pool" }
        .sum { |s| s["energy"] || 0 }

      remaining -= pool_energy

      # Recoverable energy from food (server tells us how much food can restore)
      recoverable = inventory["recoverableEnergy"] || 0

      # Food and energy bars, sorted by (type, quality) descending — matches eeriks approach
      items = (inventory["energySources"] || [])
        .select { |s| %w[food energy_bar].include?(s["type"]) && (s["amount"] || 0) > 0 }
        .sort_by { |s| [s["type"], s["quality"] || 0] }
        .reverse

      items.each do |source|
        break if remaining <= 0

        available_amount = source["amount"] || 0
        total_source_energy = source["energy"] || 0
        next if available_amount.zero? || total_source_energy.zero?

        energy_per_unit = total_source_energy / available_amount

        # Food uses recoverable budget; energy bars use remaining directly
        budget = source["type"] == "food" ? recoverable : remaining
        units_needed = [budget / energy_per_unit, available_amount].min
        next if units_needed <= 0

        sources << { quality: source["quality"] || 0, amount: units_needed }
        used_energy = units_needed * energy_per_unit
        recoverable -= used_energy if source["type"] == "food"
        remaining -= used_energy
      end

      sources
    end

    def pick_vehicle(inventory)
      vehicles = inventory["vehicles"] || []
      # Prefer recommended, then active
      v = vehicles.find { |v| v["isRecommended"] } || vehicles.find { |v| v["isActive"] } || vehicles.first
      v&.dig("id")
    end

    def extract_csrf_token
      page_source = browser.body
      match = page_source.match(/var\s+csrfToken\s*=\s*'(\w{32})'/)
      match ||= page_source.match(/name="_token"\s+value="(\w{32})"/)
      match&.[](1)
    end

    def save_screenshot(name)
      dir = File.expand_path("../../log", __dir__)
      Dir.mkdir(dir) unless Dir.exist?(dir)
      path = File.join(dir, "#{name}.png")
      browser.screenshot(path: path)
      log "Screenshot saved: #{path}"
    end

    def log(msg)
      line = "[#{Time.now.strftime('%Y-%m-%d %H:%M:%S')}]   #{msg}"
      if @log_file
        @log_file.puts(line)
        @log_file.flush
      else
        puts line
      end
    end

    def captcha_log(msg)
      log(msg)
      @captcha_log_file ||= File.open(CAPTCHA_LOG_PATH, "a")
      line = "[#{Time.now.strftime('%Y-%m-%d %H:%M:%S')}]   #{msg}"
      @captcha_log_file.puts(line)
      @captcha_log_file.flush
    end
  end

  class LoginError < StandardError; end
  class TrainError < StandardError; end
  class FightError < StandardError; end
end
