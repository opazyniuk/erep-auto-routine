# frozen_string_literal: true

require "yaml"

module Erep
  # Battle-selection country/citizen lists loaded from config/countries.yml
  # (gitignored). Falls back to config/countries.example.yml when the real file
  # is absent, so a fresh checkout and the test suite still boot.
  module Config
    CONFIG_DIR = File.expand_path("../../config", __dir__)
    PATH = File.join(CONFIG_DIR, "countries.yml")
    EXAMPLE_PATH = File.join(CONFIG_DIR, "countries.example.yml")

    data = YAML.safe_load_file(File.exist?(PATH) ? PATH : EXAMPLE_PATH) || {}

    ints = ->(key) { Array(data[key]).map(&:to_i).freeze }

    # Enemies are a single ID => permalink map; both lists derive from it so
    # they can never drift out of sync.
    enemies = data["enemies"] || {}
    ENEMIES           = enemies.keys.map(&:to_i).freeze
    ENEMY_PERMALINKS  = enemies.values.map(&:to_s).freeze
    ENEMY_CITIZEN_IDS = ints.call("enemy_citizen_ids")
    FRIENDS           = ints.call("friends")
    PRIORITY          = ints.call("priority")
  end
end
