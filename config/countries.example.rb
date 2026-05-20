# frozen_string_literal: true

# Copy to config/countries.rb (gitignored) and fill in with eRepublik country IDs.
#
#   ENEMIES  Countries to avoid fighting (and to detect as rivals when they
#            show up in a Div 3 round).
#   FRIENDS  Countries the bot is willing to fight for — a battle is only
#            considered if at least one FRIEND is on either side.

module Erep
  module Config
    ENEMIES = [].freeze
    FRIENDS = [].freeze
  end
end
