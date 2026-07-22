# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/erep/battle_selector"

class BattleSelectorTest < Minitest::Test
  SELECTOR = Erep::BattleSelector

  # Country IDs are overridden per-test so the suite is independent of the
  # gitignored config/countries.rb contents.
  PRIORITY_COUNTRY = 40 # Ukraine
  FRIEND           = 44 # Greece (non-priority friend)
  FRIEND_2         = 1  # Romania (non-priority friend)
  ENEMY            = 41 # russia

  def setup
    @originals = %i[PRIORITY FRIENDS ENEMIES].to_h { |k| [k, SELECTOR.const_get(k)] }
    set_const(:ENEMIES, [ENEMY])
    set_const(:FRIENDS, [PRIORITY_COUNTRY, FRIEND, FRIEND_2])
    set_const(:PRIORITY, [PRIORITY_COUNTRY])
  end

  def teardown
    @originals.each { |k, v| set_const(k, v) }
  end

  def test_priority_battle_returned_before_non_priority
    targets = select(
      battle(id: 100, inv: FRIEND, defn: FRIEND_2),        # non-priority
      battle(id: 200, inv: PRIORITY_COUNTRY, defn: FRIEND) # PRIORITY (listed 2nd)
    )
    assert_equal [200, 100], ids(targets)
  end

  def test_priority_country_on_defender_side_is_prioritized
    targets = select(
      battle(id: 100, inv: FRIEND, defn: FRIEND_2),         # non-priority
      battle(id: 200, inv: FRIEND_2, defn: PRIORITY_COUNTRY) # Ukraine defending
    )
    assert_equal [200, 100], ids(targets)
  end

  def test_preserves_relative_order_within_each_tier
    targets = select(
      battle(id: 1, inv: FRIEND, defn: FRIEND_2),          # non-priority
      battle(id: 2, inv: PRIORITY_COUNTRY, defn: FRIEND),  # priority
      battle(id: 3, inv: FRIEND_2, defn: FRIEND),          # non-priority
      battle(id: 4, inv: FRIEND, defn: PRIORITY_COUNTRY)   # priority
    )
    # priority tier [2, 4] first (in original order), then non-priority [1, 3]
    assert_equal [2, 4, 1, 3], ids(targets)
  end

  def test_empty_priority_leaves_order_unchanged
    set_const(:PRIORITY, [])
    targets = select(
      battle(id: 100, inv: PRIORITY_COUNTRY, defn: FRIEND_2),
      battle(id: 200, inv: FRIEND, defn: FRIEND_2)
    )
    assert_equal [100, 200], ids(targets)
  end

  def test_no_matching_priority_battles_leaves_order_unchanged
    targets = select(
      battle(id: 100, inv: FRIEND, defn: FRIEND_2),
      battle(id: 200, inv: FRIEND_2, defn: FRIEND)
    )
    assert_equal [100, 200], ids(targets)
  end

  def test_prioritization_does_not_resurrect_enemy_battles
    targets = select(
      battle(id: 100, inv: PRIORITY_COUNTRY, defn: ENEMY), # priority vs enemy → skipped
      battle(id: 200, inv: FRIEND, defn: FRIEND_2)         # non-priority, eligible
    )
    assert_equal [200], ids(targets)
  end

  def test_enemy_fighter_by_citizenship_permalink
    with_enemy_config(permalinks: %w[Russia], citizen_ids: []) do
      assert SELECTOR.enemy_fighter?(fighter(permalink: "Russia", citizen_id: 999))
      refute SELECTOR.enemy_fighter?(fighter(permalink: "Ukraine", citizen_id: 999))
    end
  end

  def test_enemy_fighter_by_citizen_id_regardless_of_citizenship
    with_enemy_config(permalinks: %w[Russia], citizen_ids: [1619581]) do
      # Friendly citizenship, but blacklisted ID → still an enemy
      assert SELECTOR.enemy_fighter?(fighter(permalink: "Ukraine", citizen_id: 1619581))
      # String IDs from the battle console are normalized
      assert SELECTOR.enemy_fighter?(fighter(permalink: "Ukraine", citizen_id: "1619581"))
      refute SELECTOR.enemy_fighter?(fighter(permalink: "Ukraine", citizen_id: 42))
    end
  end

  private

  def fighter(permalink:, citizen_id:)
    { citizenship_permalink: permalink, citizen_id: citizen_id }
  end

  def with_enemy_config(permalinks:, citizen_ids:)
    saved = { ENEMY_PERMALINKS: SELECTOR::ENEMY_PERMALINKS, ENEMY_CITIZEN_IDS: SELECTOR::ENEMY_CITIZEN_IDS }
    set_const(:ENEMY_PERMALINKS, permalinks)
    set_const(:ENEMY_CITIZEN_IDS, citizen_ids)
    yield
  ensure
    saved.each { |k, v| set_const(k, v) }
  end

  def set_const(name, value)
    SELECTOR.send(:remove_const, name)
    SELECTOR.const_set(name, value)
  end

  def ids(targets)
    targets.map { |t| t[:battle_id] }
  end

  def select(*battles)
    campaigns = { "battles" => battles.to_h { |b| [b["id"].to_s, b] } }
    SELECTOR.new(campaigns).select_targets
  end

  # Minimal fresh Div 3 round: wall at 50.0 so evaluate() keeps it.
  def battle(id:, inv:, defn:, dom: 50.0)
    {
      "id"  => id,
      "inv" => { "id" => inv },
      "def" => { "id" => defn },
      "div" => {
        "zone#{id}" => {
          "id"   => id * 10,
          "div"  => 3,
          "wall" => { "for" => inv, "dom" => dom }
        }
      }
    }
  end
end
