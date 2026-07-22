# frozen_string_literal: true

require_relative "config"

module Erep
  class BattleSelector
    ENEMIES = Erep::Config::ENEMIES
    ENEMY_PERMALINKS = Erep::Config::ENEMY_PERMALINKS
    ENEMY_CITIZEN_IDS = Erep::Config::ENEMY_CITIZEN_IDS
    FRIENDS = Erep::Config::FRIENDS
    PRIORITY = Erep::Config::PRIORITY
    DIV_KEY = "div" # division key in campaign JSON

    # A round fighter counts as an enemy when their citizenship is hostile OR
    # their citizen ID is individually blacklisted (ENEMY_CITIZEN_IDS).
    def self.enemy_fighter?(fighter)
      ENEMY_PERMALINKS.include?(fighter[:citizenship_permalink]) ||
        ENEMY_CITIZEN_IDS.include?(fighter[:citizen_id].to_i)
    end

    def initialize(campaigns_json)
      @campaigns = campaigns_json
    end

    def select_targets
      battles = Array(@campaigns["battles"]&.values || @campaigns)

      targets = battles.filter_map { |battle| evaluate(battle) }
      prioritize(targets)
    end

    private

    # Battles involving a PRIORITY country (e.g. Ukraine) are returned first so
    # they get fuel/energy before the budget runs out. Order within each tier is
    # preserved; empty PRIORITY leaves order unchanged.
    def prioritize(targets)
      priority, rest = targets.partition do |target|
        target[:sides].any? { |side| PRIORITY.include?(side[:country_id].to_i) }
      end
      priority + rest
    end

    def evaluate(battle)
      invader_id = battle.dig("inv", "id") || battle["invaderId"]
      defender_id = battle.dig("def", "id") || battle["defenderId"]
      battle_id = battle["id"] || battle["battle_id"]

      return nil if involves_enemy?(invader_id, defender_id)
      return nil unless involves_friend?(invader_id, defender_id)

      div3 = find_div3_zone(battle)
      return nil unless div3
      return nil if div3_ended?(div3)

      zone_id = div3["id"] || div3["battleZoneId"]

      # Pre-filter: wall at 50.0 means likely fresh round (no fighters yet)
      # Not 100% reliable (equal damage keeps wall at 50) but eliminates most occupied rounds
      dom = div3.dig("wall", "dom")
      return nil unless dom && dom.to_f == 50.0

      # wall.for = country ID the wall favors, wall.dom = domination % (0-100)
      wall_for_country = div3.dig("wall", "for")
      dom_pct = div3.dig("wall", "dom") || 50.0

      # dom_pct is for the wall_for_country side
      if wall_for_country.to_i == invader_id.to_i
        invader_wall = dom_pct
        defender_wall = 100 - dom_pct
      else
        defender_wall = dom_pct
        invader_wall = 100 - dom_pct
      end

      sides = [
        { country_id: defender_id, wall_pct: defender_wall, role: :defender },
        { country_id: invader_id, wall_pct: invader_wall, role: :invader }
      ]

      { battle_id: battle_id, zone_id: zone_id, sides: sides }
    end

    def involves_enemy?(invader_id, defender_id)
      ENEMIES.include?(invader_id.to_i) || ENEMIES.include?(defender_id.to_i)
    end

    def involves_friend?(invader_id, defender_id)
      FRIENDS.include?(invader_id.to_i) || FRIENDS.include?(defender_id.to_i)
    end

    def find_div3_zone(battle)
      divs = battle[DIV_KEY] || battle["divisions"] || {}
      # Divisions are keyed by zone ID (e.g. "39498323"), each has a "div" field (1-4, 11)
      divs.each_value do |zone|
        return zone if zone.is_a?(Hash) && zone["div"] == 3
      end
      nil
    end

    def div3_ended?(div3)
      div3["division_end"] == true || !div3["end"].nil?
    end

  end
end
