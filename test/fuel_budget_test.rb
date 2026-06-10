# frozen_string_literal: true

require "minitest/autorun"
require "date"
require_relative "../lib/erep/fuel_budget"

class FuelBudgetTest < Minitest::Test
  # Fight day rolls at 10:00 Kyiv. Each row is one moment in the week,
  # and the expected reserve = remaining_blocks_after_today × 3.
  # Block 0 = Tue 10:00 – Wed 09:59 (reserve 18)
  # Block 6 = Mon 10:00 – Tue 09:59 (reserve 0, "burn it all" window)
  EXPECTED = [
    ["2026-06-09 10:00", 6, 18], # Tue post-reset (start of block 0)
    ["2026-06-09 23:59", 6, 18], # Tue late evening (still block 0)
    ["2026-06-10 09:59", 6, 18], # Wed 09:59 (last minute of block 0)
    ["2026-06-10 10:00", 5, 15], # Wed 10:00 (block 1 begins)
    ["2026-06-10 14:30", 5, 15], # Wed afternoon
    ["2026-06-11 08:00", 5, 15], # Thu 08:00 (still block 1)
    ["2026-06-11 10:00", 4, 12], # Thu 10:00 (block 2)
    ["2026-06-12 12:00", 3,  9], # Fri 12:00 (block 3)
    ["2026-06-13 20:00", 2,  6], # Sat 20:00 (block 4)
    ["2026-06-14 06:00", 2,  6], # Sun 06:00 (still block 4)
    ["2026-06-14 10:00", 1,  3], # Sun 10:00 (block 5)
    ["2026-06-15 09:59", 1,  3], # Mon 09:59 (last minute of block 5)
    ["2026-06-15 10:00", 0,  0], # Mon 10:00 (block 6 begins — burn-it-all)
    ["2026-06-15 23:59", 0,  0], # Mon late (still block 6)
    ["2026-06-16 00:00", 0,  0], # Tue pre-reset
    ["2026-06-16 09:59", 0,  0]  # Tue right before reset
  ].freeze

  EXPECTED.each do |time_str, exp_remaining_days, exp_reserved|
    define_method "test_#{time_str.gsub(/\W/, '_')}_reserves_#{exp_reserved}" do
      now = Time.new(*time_str.scan(/\d+/).map(&:to_i))
      budget = Erep::FuelBudget.new(fuel_left: 70, now: now)
      assert_equal 70 - exp_reserved, budget.available_today,
                   "#{time_str} (#{Date::DAYNAMES[now.wday]}) — expected #{exp_remaining_days} days remaining, reserve #{exp_reserved}"
    end
  end

  def test_low_fuel_clamps_to_zero
    # Tue post-reset, only 10 fuel, would reserve 18 → clamp to 0
    now = Time.new(2026, 6, 9, 10, 0)
    budget = Erep::FuelBudget.new(fuel_left: 10, now: now)
    assert_equal 0, budget.available_today
    refute budget.can_fight?
  end

  def test_burn_window_uses_all_fuel
    # Mon ≥10:00 — burn-it-all window starts
    now = Time.new(2026, 6, 15, 10, 0)
    assert_equal 7, Erep::FuelBudget.new(fuel_left: 7, now: now).available_today

    # Tue <10:00 — still burn window
    now = Time.new(2026, 6, 16, 9, 59)
    assert_equal 7, Erep::FuelBudget.new(fuel_left: 7, now: now).available_today
  end

  def test_just_before_burn_window_still_reserves
    # Mon 09:59 — last minute of block 5, reserve 3
    now = Time.new(2026, 6, 15, 9, 59)
    assert_equal 4, Erep::FuelBudget.new(fuel_left: 7, now: now).available_today
  end

  def test_consume_reduces_remaining
    now = Time.new(2026, 6, 9, 10, 0)
    budget = Erep::FuelBudget.new(fuel_left: 70, now: now)
    assert_equal 52, budget.remaining
    budget.consume(10)
    assert_equal 42, budget.remaining
    budget.consume(42)
    refute budget.can_fight?
  end
end
