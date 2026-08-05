# frozen_string_literal: true

require "json"

module Erep
  class Browser
    # Drives a single deploy: reads the deploy inventory, budgets energy across
    # pool/food/bars, starts the deploy and reads back the report. Switching sides
    # on the battlefield lives here too.
    class Deployment
      def initialize(session, verification)
        @session = session
        @verification = verification
      end

      def deploy(battle_id:, zone_id:, side_country_id:, total_energy:, weapon_quality: 7)
        token = @session.csrf_token
        raise FightError, "No CSRF token for deploy" unless token

        inventory = fetch_deploy_inventory(token: token, battle_id: battle_id,
                                           side_country_id: side_country_id, zone_id: zone_id)

        # A captcha-gated response carries no energy fields — that's a verification
        # gate, NOT an empty pool. Solve and re-fetch once before trusting the numbers;
        # otherwise poolEnergy reads nil→0 and we skip a beatable rival (see 917941).
        if inventory["captcha"] || !inventory.key?("poolEnergy")
          log "Deploy inventory gated (captcha/missing fields), verifying + retrying..."
          @verification.handle_verification
          inventory = fetch_deploy_inventory(token: token, battle_id: battle_id,
                                             side_country_id: side_country_id, zone_id: zone_id)
        end

        blocked = deploy_blocked_reason(inventory)
        if blocked
          log blocked
          return nil
        end

        pool = inventory["poolEnergy"] || 0
        recoverable = inventory["recoverableEnergy"] || 0
        available = pool + recoverable
        if available < total_energy
          log "Not enough energy for deploy: available=#{available} (pool=#{pool}, recoverable=#{recoverable}), requested=#{total_energy}"
          return nil
        end

        total_energy = clamp_energy(inventory, total_energy)
        log "Deploy inventory OK: weapons=#{inventory["weapons"]&.size}, poolEnergy=#{inventory["poolEnergy"]}, maxEnergy=#{inventory["maxEnergy"] || total_energy}"

        result = start_deploy(token: token, battle_id: battle_id, zone_id: zone_id,
                              side_country_id: side_country_id, weapon_quality: weapon_quality,
                              total_energy: total_energy, inventory: inventory)
        return nil unless result

        report_deploy(result["deploymentId"])
        result
      end

      def switch_side(battle_id:, side_country_id:, zone_id:)
        token = @session.csrf_token
        @session.evaluate(<<~JS)
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
              window.__switchResult = JSON.stringify(await resp.json());
            } catch(e) { window.__switchResult = JSON.stringify({error: e.message}); }
          })()
        JS
        sleep 2
        json = @session.evaluate("window.__switchResult") rescue nil
        result = JSON.parse(json || "{}")

        if result["error"] == true
          log "Switch side failed: #{result["message"]}"
        else
          log "Switched to side #{side_country_id}"
        end
        result
      end

      def fetch_deploy_inventory(token:, battle_id:, side_country_id:, zone_id:)
        @session.evaluate(<<~JS)
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
              window.__deployInventory = JSON.stringify(await resp.json());
            } catch(e) { window.__deployInventory = JSON.stringify({error: e.message}); }
          })()
        JS
        sleep 2
        inv_json = @session.evaluate("window.__deployInventory") rescue nil
        JSON.parse(inv_json || "{}")
      end

      def fetch_deploy_report(deployment_id)
        token = @session.csrf_token
        return nil unless token

        @session.evaluate(<<~JS)
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
              window.__deployReport = JSON.stringify(await resp.json());
            } catch(e) { window.__deployReport = JSON.stringify({error: e.message}); }
          })()
        JS
        sleep 2
        json = @session.evaluate("window.__deployReport") rescue nil
        JSON.parse(json || "{}")
      end

      private

      # Returns a log message when the inventory says we can't deploy, else nil.
      def deploy_blocked_reason(inventory)
        return "Deploy inventory error: #{inventory.inspect}" if inventory["error"] == true
        return "Deploy unavailable: #{inventory["message"]}" if inventory["message"]
        if inventory["activeDeployment"]
          return "Active deployment already running (id=#{inventory["activeDeployment"]}), skipping"
        end
        # Still gated after verification? Bail honestly instead of misreporting a
        # missing inventory as an empty energy pool.
        return "Deploy inventory still gated after verification (no energy fields), skipping" unless inventory.key?("poolEnergy")

        nil
      end

      def clamp_energy(inventory, total_energy)
        min_energy = inventory["minEnergy"] || 0
        max_energy = inventory["maxEnergy"] || total_energy
        return total_energy if total_energy.between?(min_energy, max_energy)

        log "Deploy energy #{total_energy} outside bounds [#{min_energy}, #{max_energy}], clamping"
        [[total_energy, min_energy].max, max_energy].min
      end

      def start_deploy(token:, battle_id:, zone_id:, side_country_id:, weapon_quality:, total_energy:, inventory:)
        # Pool energy is auto-consumed; only food/bars are sent explicitly.
        energy_sources = build_energy_sources(inventory, total_energy)
        vehicle = pick_vehicle(inventory)
        energy_source_js = energy_sources.each_with_index.map { |src, i|
          "formData.append('energySources[#{i}][quality]', '#{src[:quality]}');\n" \
          "formData.append('energySources[#{i}][amount]', '#{src[:amount]}');"
        }.join("\n            ")

        @session.evaluate(<<~JS)
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
              window.__deployResult = JSON.stringify(await resp.json());
            } catch(e) { window.__deployResult = JSON.stringify({error: e.message}); }
          })()
        JS
        sleep 3
        result_json = @session.evaluate("window.__deployResult") rescue nil
        result = JSON.parse(result_json || "{}")

        if result["error"] == true
          log "Deploy failed: #{result["message"]}"
          return nil
        end

        log "Deploy OK: deploymentId=#{result["deploymentId"]}, energy=#{total_energy}, fuelLeft=#{result.dig("data", "fuelLeft")}"
        result
      end

      def report_deploy(deployment_id)
        return unless deployment_id

        sleep 3
        report = fetch_deploy_report(deployment_id)
        if report&.dig("error")
          sleep 3
          report = fetch_deploy_report(deployment_id)
        end

        return unless report && report["data"]

        data = report["data"]
        log "Deploy report: damage=#{data["damage"]}, energySpent=#{data["energySpent"]}, prestige=#{data.dig("rewards", "prestigePoints")}"
      end

      # Food uses the recoverable-energy budget; energy bars draw from remaining.
      # Sorted by (type, quality) descending — matches the eeriks approach.
      def build_energy_sources(inventory, total_energy)
        sources = []
        remaining = total_energy

        pool_energy = (inventory["energySources"] || [])
                      .select { |s| s["type"] == "pool" }
                      .sum { |s| s["energy"] || 0 }
        remaining -= pool_energy

        recoverable = inventory["recoverableEnergy"] || 0

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
        vehicle = vehicles.find { |v| v["isRecommended"] } || vehicles.find { |v| v["isActive"] } || vehicles.first
        vehicle&.dig("id")
      end

      def log(msg)
        @session.log(msg)
      end
    end
  end
end
