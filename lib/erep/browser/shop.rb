 # frozen_string_literal: true

require "json"

module Erep
  class Browser
    # VIP shop and monetary market: daily VIP points, weekly energy-bar packs,
    # and buying gold with in-game currency.
    class Shop
      GOLD_CURRENCY_ID = 62
      DAILY_GOLD_TARGET = 10.0
      WEEKLY_ENERGY_BAR_PACKS = %w[energy_bars double_energy_bars].freeze

      def initialize(session)
        @session = session
      end

      def collect_vip_points
        log "Collecting VIP points..."
        @session.ensure_on_main_page

        @session.go_to("#{BASE_URL}/en/main/vip-shop")
        sleep 4

        unless @session.current_url.include?("vip-shop")
          log "VIP shop redirected to #{@session.current_url} — skipping"
          return
        end

        state = @session.evaluate(<<~JS)
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
        verified = @session.evaluate(<<~JS)
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
      rescue StandardError => e
        log "VIP collection failed: #{e.message}"
        save_screenshot("vip_error")
        :failure
      end

      # Buy up to `amount` gold from the monetary market using available CC.
      # Walks offers cheapest-first and partial-fills if CC can't cover the full target.
      def buy_gold(amount: DAILY_GOLD_TARGET)
        log "Buying up to #{amount} gold from monetary market..."
        @session.ensure_on_main_page

        token = @session.csrf_token
        raise TrainError, "Could not extract CSRF token for buy_gold" unless token

        @session.evaluate(<<~JS)
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
        result_json = @session.evaluate("window.__buyGoldResult") rescue nil
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
      rescue StandardError => e
        log "Buy gold failed: #{e.message}"
        save_screenshot("buy_gold_error")
        :failure
      end

      def purchase_weekly_energy_bars
        log "Weekly energy bar purchase..."
        @session.ensure_on_main_page

        @session.go_to("#{BASE_URL}/en/main/vip-shop")
        sleep 4

        unless @session.current_url.include?("vip-shop")
          log "VIP shop redirected to #{@session.current_url} — skipping weekly purchases"
          return :failure
        end

        results = WEEKLY_ENERGY_BAR_PACKS.map { |id| [id, purchase_vip_pack(id)] }
        results.each { |id, status| log "  #{id}: #{status}" }

        statuses = results.map(&:last)
        return :success if statuses.all? { |s| s == :purchased || s == :already_purchased }

        :partial
      rescue StandardError => e
        log "Weekly energy bar purchase failed: #{e.message}"
        save_screenshot("weekly_purchase_error")
        :failure
      end

      private

      def purchase_vip_pack(pack_id)
        state = @session.evaluate(<<~JS)
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
        confirm = @session.evaluate(<<~JS)
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
          verified = @session.evaluate(<<~JS)
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

      def log(msg)
        @session.log(msg)
      end

      def save_screenshot(name)
        @session.save_screenshot(name)
      end
    end
  end
end
