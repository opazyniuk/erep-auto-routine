# frozen_string_literal: true

# Copy to config/countries.rb (gitignored) and fill in with eRepublik country IDs.
#
#   ENEMIES           Country IDs to avoid fighting and to detect as rivals
#                     when they show up in a Div 3 round.
#   ENEMY_PERMALINKS  String permalinks for the same enemies — the battle-console
#                     fighterData payload exposes citizenship only as
#                     `country_permalink` / `country_name`, not as a numeric ID.
#                     Keep aligned 1:1 with ENEMIES.
#   FRIENDS           Country IDs the bot is willing to fight for — a battle is
#                     only considered if at least one FRIEND is on either side.

module Erep
  module Config
    ENEMIES = [].freeze
    ENEMY_PERMALINKS = [].freeze
    FRIENDS = [].freeze
  end
end
