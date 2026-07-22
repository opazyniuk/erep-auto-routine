# frozen_string_literal: true

require "date"
require_relative "browser"
require_relative "fuel_budget"
require_relative "battle_selector"

module Erep
  class Fighter
    LOG_PATH = File.expand_path("../../log/fight.log", __dir__)
    LOG_FILE = File.open(LOG_PATH, "a")

    def initialize(email:, password:)
      @email = email
      @password = password
    end

    def run
      # Truncate log file at start of each session — keep only current run
      File.truncate(LOG_PATH, 0) if File.exist?(LOG_PATH)
      LOG_FILE.seek(0)

      log separator
      log "Starting fight session"
      @browser = Browser.new(log_file: LOG_FILE)

      @browser.login(@email, @password)

      @browser.handle_verification

      # 1. Safety gate: Infantry Kit must be active (prevents XP gain)
      unless @browser.infantry_kit_active?
        log "ABORT: Infantry Kit not active — fighting would gain XP"
        return :no_infantry_kit
      end

      # 2. Read fuel budget
      fuel = @browser.read_fuel_balance
      unless fuel
        log "ABORT: Could not read fuel balance"
        return :no_fuel_data
      end
      budget = FuelBudget.new(fuel_left: fuel[:left])
      log "Fuel: #{fuel[:left]}/#{fuel[:max]}, available today: #{budget.available_today}"
      unless budget.can_fight?
        log "No fuel available today (need reserve for remaining days)"
        return :no_fuel
      end

      # 2b. Record XP before fighting to detect accidental XP gain
      account = @browser.fetch_account_info
      @xp_before = account&.dig("xp") || account&.dig("citizenXp")
      log "XP before fighting: #{@xp_before}" if @xp_before

      # 3. Handle any pending account verification
      unless @browser.handle_verification
        log "ABORT: Account verification required and could not be resolved"
        return :verification_blocked
      end

      # 4. Fetch campaigns
      campaigns = @browser.fetch_campaigns

      # 5. Select eligible battles
      selector = BattleSelector.new(campaigns)
      targets = selector.select_targets
      log "Found #{targets.size} eligible battle(s)"

      if targets.empty?
        log "No eligible battles found"
        collect_rewards
        return :no_battles
      end

      # 6. Fight loop
      targets.each do |target|
        unless budget.can_fight?
          log "Fuel budget exhausted"
          break
        end

        energy = @browser.read_energy
        unless energy && energy[:current] >= 200
          log "Not enough energy (#{energy&.dig(:current) || 'unknown'}/200), stopping"
          break
        end

        fight_battle(target, budget)

        # Handle captcha if it appeared during fighting
        unless @browser.handle_verification
          log "Captcha appeared mid-fight and could not be resolved, stopping"
          break
        end

        # Check XP didn't increase (would mean Infantry Kit failed)
        if @xp_before
          account = @browser.fetch_account_info
          xp_now = account&.dig("xp") || account&.dig("citizenXp")
          if xp_now && xp_now > @xp_before
            log "SAFETY ABORT: XP increased from #{@xp_before} to #{xp_now} — Infantry Kit may have failed"
            break
          end
        end
      end

      # 6. Collect rewards
      collect_rewards

      # 7. Return to home location
      safe_step("Travel home") { @browser.travel_home }

      log "Fight session complete"
      log separator
      true
    rescue => e
      log "FAILED | #{e.message}"
      log e.backtrace.first(5).join("\n")
      log separator
      false
    ensure
      @browser&.quit
    end

    private

    # Conservative damage-per-energy estimate (q7 weapons + boosters)
    DAMAGE_PER_ENERGY = 80_000
    RIVAL_MAX_DAMAGE_PER_SIDE = 50_000_000

    def fight_battle(target, budget)
      battle_id = target[:battle_id]
      zone_id = target[:zone_id]
      sides = target[:sides]

      log "------------------------------------------------------------"
      log "Fighting battle #{battle_id} (zone #{zone_id})"

      # Navigate to battle page
      @browser.go_to("#{Browser::BASE_URL}/en/military/battlefield/#{battle_id}")
      sleep 3

      # Check if battle/round is still active before deploying
      unless @browser.battle_zone_active?(zone_id)
        log "Battle zone #{zone_id} no longer active, skipping"
        return
      end

      # Analyze fighters in round
      round_fighters = @browser.analyze_round_fighters(battle_id, zone_id)

      if round_fighters.any?
        enemy_fighters = round_fighters.select { |f| BattleSelector.enemy_fighter?(f) }

        if enemy_fighters.empty?
          log "Round occupied by non-enemy, skipping battle #{battle_id}"
          return
        end

        log "RIVAL MODE: Enemy citizen(s) detected — #{enemy_fighters.map { |f| "#{f[:name]} (#{f[:damage]} dmg)" }.join(', ')}"
        rival_mode = true
        max_enemy_damage = enemy_fighters.map { |f| f[:damage] }.max
      end

      # Determine winning/losing by overall battle score (campaign points), not round wall
      battle_score = @browser.read_battle_score
      if battle_score && battle_score[:invader_points] && battle_score[:defender_points]
        sides.each do |s|
          case s[:role]
          when :invader then s[:battle_points] = battle_score[:invader_points].to_i
          when :defender then s[:battle_points] = battle_score[:defender_points].to_i
          end
        end
        log "Battle score: #{sides.map { |s| "#{s[:country_id]}(#{s[:role]})=#{s[:battle_points]}pts" }.join(' vs ')}"
      end

      # Fallback to round wall % if battle score unavailable
      unless sides.all? { |s| s[:battle_points] }
        live_wall = @browser.read_wall_state
        if live_wall
          log "Wall fallback: #{live_wall[:left_country]} #{live_wall[:left_pct]}% vs #{live_wall[:right_country]} #{live_wall[:right_pct]}%"
          sides.each do |s|
            s[:battle_points] ||= if s[:country_id].to_s == live_wall[:left_country].to_s
                                    live_wall[:left_pct]
                                  elsif s[:country_id].to_s == live_wall[:right_country].to_s
                                    live_wall[:right_pct]
                                  else
                                    50
                                  end
          end
        end
      end

      losing, winning = sides.sort_by { |s| [s[:battle_points] || 50, s[:role] == :defender ? 1 : 0] }

      # Ensure 50% damage booster is active before first deploy
      unless @booster_checked
        @browser.ensure_damage_booster
        @booster_checked = true
      end

      # Decide energy per side
      if rival_mode
        max_energy_cap = (RIVAL_MAX_DAMAGE_PER_SIDE / DAMAGE_PER_ENERGY.to_f).ceil

        # Calculate per-side: beat enemy damage on that side with 30% buffer
        losing_enemy_dmg = enemy_fighters.select { |f| f[:side_country_id] == losing[:country_id].to_i }.map { |f| f[:damage] }.max || 0
        winning_enemy_dmg = enemy_fighters.select { |f| f[:side_country_id] == winning[:country_id].to_i }.map { |f| f[:damage] }.max || 0

        losing_energy = [[(losing_enemy_dmg * 1.3 / DAMAGE_PER_ENERGY).ceil, 40].max, max_energy_cap].min
        winning_energy = [[(winning_enemy_dmg * 1.3 / DAMAGE_PER_ENERGY).ceil, 160].max, max_energy_cap].min

        min_required = losing_energy + winning_energy
        log "Rival energy: losing=#{losing_energy} (vs #{losing_enemy_dmg} dmg) + winning=#{winning_energy} (vs #{winning_enemy_dmg} dmg) = #{min_required} total, cap #{RIVAL_MAX_DAMAGE_PER_SIDE / 1_000_000}M/side"
      else
        losing_energy = 40
        winning_energy = 160
        min_required = 200
      end

      # Check energy from page header
      energy = @browser.read_energy
      unless energy && energy[:current] >= min_required
        log "Not enough energy (#{energy&.dig(:current) || 'unknown'}/#{min_required}), skipping battle"
        return
      end

      # Deploy on losing side
      log "Deploying on losing side (#{losing[:country_id]}, #{losing[:wall_pct]}%) — #{losing_energy} energy"
      @browser.switch_side(battle_id: battle_id, side_country_id: losing[:country_id], zone_id: zone_id)
      result1 = @browser.deploy(battle_id: battle_id, zone_id: zone_id,
                                side_country_id: losing[:country_id],
                                weapon_quality: 7, total_energy: losing_energy)

      unless result1
        log "Losing side deploy failed, skipping winning side"
        return
      end

      # Deploy on winning side
      log "Deploying on winning side (#{winning[:country_id]}, #{winning[:wall_pct]}%) — #{winning_energy} energy"
      @browser.switch_side(battle_id: battle_id, side_country_id: winning[:country_id], zone_id: zone_id)
      result2 = @browser.deploy(battle_id: battle_id, zone_id: zone_id,
                                side_country_id: winning[:country_id],
                                weapon_quality: 7, total_energy: winning_energy)

      budget.consume(1) if result1 || result2

      log "Battle #{battle_id} done (losing=#{result1 ? 'OK' : 'FAIL'}, winning=#{result2 ? 'OK' : 'FAIL'})"
    end

    def collect_rewards
      safe_step("Daily challenge") { @browser.collect_daily_challenge }
      safe_step("Weekly challenge") { @browser.collect_weekly_challenge }
    end

    def safe_step(name)
      yield
    rescue => e
      log "#{name} failed: #{e.message}"
      log e.backtrace.first(3).join("\n")
      :error
    end

    def separator
      "=" * 60
    end

    def log(msg)
      line = "[#{Time.now.strftime('%Y-%m-%d %H:%M:%S')}] #{msg}"
      LOG_FILE.puts(line)
      LOG_FILE.flush
    end
  end
end
