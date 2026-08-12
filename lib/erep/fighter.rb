# frozen_string_literal: true

require "date"
require_relative "browser"
require_relative "logger"
require_relative "fuel_budget"
require_relative "battle_selector"

module Erep
  class Fighter
    LOG_PATH = File.expand_path("../../log/fight.log", __dir__)
    LOG_FILE = File.open(LOG_PATH, "a")

    def initialize(email:, password:)
      @email = email
      @password = password
      @logger = Logger.new(LOG_FILE)
    end

    def run
      # Keep only the current run in the log
      File.truncate(LOG_PATH, 0) if File.exist?(LOG_PATH)
      LOG_FILE.seek(0)

      @logger.separator
      log "Starting fight session"
      @browser = Browser.new(log_file: LOG_FILE)

      @browser.login(@email, @password)
      @browser.handle_verification

      # Safety gate: fighting without the Infantry Kit gains XP
      unless @browser.infantry_kit_active?
        log "ABORT: Infantry Kit not active — fighting would gain XP"
        return :no_infantry_kit
      end

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

      # Baseline XP so we can detect accidental XP gain mid-session
      account = @browser.fetch_account_info
      @xp_before = account&.dig("xp") || account&.dig("citizenXp")
      log "XP before fighting: #{@xp_before}" if @xp_before

      unless @browser.handle_verification
        log "ABORT: Account verification required and could not be resolved"
        return :verification_blocked
      end

      campaigns = @browser.fetch_campaigns
      targets = BattleSelector.new(campaigns).select_targets
      allied, neutral = targets.partition { |target| target[:friendly] }
      log "Found #{targets.size} eligible battle(s): #{allied.size} allied, #{neutral.size} neutral"

      if targets.empty?
        log "No eligible battles found"
        collect_rewards
        return :no_battles
      end

      fight_targets(targets, budget)

      collect_rewards
      safe_step("Travel home") { @browser.travel_home }

      log "Fight session complete"
      @logger.separator
      true
    rescue => e
      log "FAILED | #{e.message}"
      log e.backtrace.first(5).join("\n")
      @logger.separator
      false
    ensure
      @browser&.quit
    end

    private

    # Conservative damage-per-energy estimate (q7 weapons + boosters)
    DAMAGE_PER_ENERGY = 80_000
    RIVAL_MAX_DAMAGE_PER_SIDE = 50_000_000
    # A deploy consumes a random 10-40 energy per hit (the deploy inventory reports
    # minEnergy: 10) and stops once what is left is smaller than the next hit, so a
    # request lands anywhere from the full amount to 30 short.
    MIN_HIT_ENERGY = 10
    MAX_HIT_ENERGY = 40
    ROUND_DIVIDER = "-" * 60

    def fight_targets(targets, budget)
      neutral_tier_announced = false

      targets.each do |target|
        if !target[:friendly] && !neutral_tier_announced
          log "Allied battles exhausted — falling back to neutral battles"
          neutral_tier_announced = true
        end

        unless budget.can_fight?
          log "Fuel budget exhausted"
          break
        end

        energy = @browser.read_energy
        unless energy && energy[:current] >= 200
          log "Not enough energy (#{energy&.dig(:current) || 'unknown'}/200), stopping"
          break
        end

        # A transient CDP/Ferrum timeout on one battle's deploy must not kill the
        # whole session — log it and move on to the next battle (see battle 924445,
        # winning-side deploy timing out at 30s and aborting the entire run).
        begin
          fight_battle(target, budget)
        rescue => e
          log "Battle #{target[:battle_id]} errored mid-fight (#{e.message}) — skipping to next"
        end

        unless @browser.handle_verification
          log "Captcha appeared mid-fight and could not be resolved, stopping"
          break
        end

        break if xp_gained?
      end
    end

    def fight_battle(target, budget)
      battle_id, zone_id, sides = target.values_at(:battle_id, :zone_id, :sides)

      log ROUND_DIVIDER
      log "Fighting battle #{battle_id} (zone #{zone_id})"

      @browser.go_to("#{Browser::BASE_URL}/en/military/battlefield/#{battle_id}")
      sleep 3

      unless @browser.battle_zone_active?(zone_id)
        log "Battle zone #{zone_id} no longer active, skipping"
        return
      end

      enemy_fighters = detect_enemy_fighters(battle_id, zone_id)
      return if enemy_fighters == :skip

      losing, winning = resolve_sides(sides)
      activate_booster_once

      plan = energy_plan(enemy_fighters, losing, winning)

      energy = @browser.read_energy
      unless energy && energy[:current] >= plan[:min_required]
        log "Not enough energy (#{energy&.dig(:current) || 'unknown'}/#{plan[:min_required]}), skipping battle"
        return
      end

      return if round_closing?(battle_id)

      deploy_both_sides(battle_id, zone_id, losing, winning, plan, budget)
    end

    # True (and logs) when the round isn't in a deployable state — the battle is
    # finished, or we're between rounds (zone not started), which is the transition
    # window where a deploy POST comes back "Battle zone unavailable". Nil state
    # (page didn't expose SERVER_DATA) is treated as deployable so we still try.
    def round_closing?(battle_id)
      state = @browser.round_state
      return false unless state

      if state[:finished] || state[:started] == false
        log "Round finished/between rounds, skipping battle #{battle_id}"
        return true
      end

      false
    end

    # Enemy fighters occupying the round ([] when clear or empty), or :skip when a
    # non-enemy already holds it.
    def detect_enemy_fighters(battle_id, zone_id)
      round_fighters = @browser.analyze_round_fighters(battle_id, zone_id)
      return [] if round_fighters.empty?

      enemies = round_fighters.select { |f| BattleSelector.enemy_fighter?(f) }
      if enemies.empty?
        log "Round occupied by non-enemy, skipping battle #{battle_id}"
        return :skip
      end

      log "RIVAL MODE: Enemy citizen(s) detected — #{enemies.map { |f| "#{f[:name]} (#{f[:damage]} dmg)" }.join(', ')}"
      enemies
    end

    # Assigns battle_points from campaign score (falling back to the round wall)
    # and returns [losing_side, winning_side].
    def resolve_sides(sides)
      score = @browser.read_battle_score
      if score && score[:invader_points] && score[:defender_points]
        sides.each do |s|
          case s[:role]
          when :invader then s[:battle_points] = score[:invader_points].to_i
          when :defender then s[:battle_points] = score[:defender_points].to_i
          end
        end
        log "Battle score: #{sides.map { |s| "#{s[:country_id]}(#{s[:role]})=#{s[:battle_points]}pts" }.join(' vs ')}"
      end

      apply_wall_fallback(sides) unless sides.all? { |s| s[:battle_points] }

      sides.sort_by { |s| [s[:battle_points] || 50, s[:role] == :defender ? 1 : 0] }
    end

    def apply_wall_fallback(sides)
      wall = @browser.read_wall_state
      return unless wall

      log "Wall fallback: #{wall[:left_country]} #{wall[:left_pct]}% vs #{wall[:right_country]} #{wall[:right_pct]}%"
      sides.each do |s|
        s[:battle_points] ||= if s[:country_id].to_s == wall[:left_country].to_s
                                wall[:left_pct]
                              elsif s[:country_id].to_s == wall[:right_country].to_s
                                wall[:right_pct]
                              else
                                50
                              end
      end
    end

    def activate_booster_once
      return if @booster_checked

      @browser.ensure_damage_booster
      @booster_checked = true
    end

    # Energy to spend per side. Default 40/160 split; in rival mode, enough to beat
    # each side's strongest enemy by 30%, floored at 40/160 and capped per side.
    def energy_plan(enemy_fighters, losing, winning)
      return { losing_energy: 40, winning_energy: 160, min_required: 200 } if enemy_fighters.empty?

      cap = whole_hits(RIVAL_MAX_DAMAGE_PER_SIDE / DAMAGE_PER_ENERGY.to_f, :floor)
      losing_dmg = max_enemy_damage(enemy_fighters, losing)
      winning_dmg = max_enemy_damage(enemy_fighters, winning)
      losing_energy = [[rival_energy(losing_dmg), 40].max, cap].min
      winning_energy = [[rival_energy(winning_dmg), 160].max, cap].min
      min_required = losing_energy + winning_energy
      log "Rival energy: losing=#{losing_energy} (vs #{losing_dmg} dmg) + winning=#{winning_energy} (vs #{winning_dmg} dmg) = #{min_required} total, cap #{RIVAL_MAX_DAMAGE_PER_SIDE / 1_000_000}M/side"
      { losing_energy: losing_energy, winning_energy: winning_energy, min_required: min_required }
    end

    # Round the rival target up to a whole hit step — a request of 82 can only ever
    # land 80 — then add a full max-hit of margin so the target is still cleared when
    # the tail hit doesn't fit in what's left. The per-side cap rounds down instead,
    # so the margin can never push us over it.
    def rival_energy(rival_damage)
      whole_hits(rival_damage * 1.3 / DAMAGE_PER_ENERGY, :ceil) + MAX_HIT_ENERGY
    end

    def whole_hits(energy, rounding)
      (energy / MIN_HIT_ENERGY.to_f).public_send(rounding) * MIN_HIT_ENERGY
    end

    def max_enemy_damage(enemy_fighters, side)
      enemy_fighters.select { |f| f[:side_country_id] == side[:country_id].to_i }.map { |f| f[:damage] }.max || 0
    end

    def deploy_both_sides(battle_id, zone_id, losing, winning, plan, budget)
      log "Deploying on losing side (#{losing[:country_id]}, #{losing[:wall_pct]}%) — #{plan[:losing_energy]} energy"
      @browser.switch_side(battle_id: battle_id, side_country_id: losing[:country_id], zone_id: zone_id)
      result1 = @browser.deploy(battle_id: battle_id, zone_id: zone_id,
                                side_country_id: losing[:country_id],
                                weapon_quality: 7, total_energy: plan[:losing_energy])

      unless result1
        log "Losing side deploy failed, skipping winning side"
        return
      end

      log "Deploying on winning side (#{winning[:country_id]}, #{winning[:wall_pct]}%) — #{plan[:winning_energy]} energy"
      @browser.switch_side(battle_id: battle_id, side_country_id: winning[:country_id], zone_id: zone_id)
      result2 = @browser.deploy(battle_id: battle_id, zone_id: zone_id,
                                side_country_id: winning[:country_id],
                                weapon_quality: 7, total_energy: plan[:winning_energy])

      budget.consume(1) if result1 || result2
      log "Battle #{battle_id} done (losing=#{result1 ? 'OK' : 'FAIL'}, winning=#{result2 ? 'OK' : 'FAIL'})"
    end

    # True (and logs) when XP rose since baseline — the Infantry Kit likely lapsed.
    def xp_gained?
      return false unless @xp_before

      account = @browser.fetch_account_info
      xp_now = account&.dig("xp") || account&.dig("citizenXp")
      return false unless xp_now && xp_now > @xp_before

      log "SAFETY ABORT: XP increased from #{@xp_before} to #{xp_now} — Infantry Kit may have failed"
      true
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

    def log(msg)
      @logger.log(msg)
    end
  end
end
