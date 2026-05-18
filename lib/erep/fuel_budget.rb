# frozen_string_literal: true

module Erep
  class FuelBudget
    attr_reader :fuel_left, :available_today

    def initialize(fuel_left:)
      @fuel_left = fuel_left
      @spent = 0
      @available_today = calculate_available
    end

    def can_fight?
      remaining > 0
    end

    def remaining
      available_today - @spent
    end

    def consume(amount = 1)
      @spent += amount
    end

    private

    def calculate_available
      reserved = remaining_days_in_week * 3
      [fuel_left - reserved, 0].max
    end

    # Days remaining in the eRepublik week AFTER today.
    # Fuel resets on Tuesday ~10:00 Kyiv time.
    # E.g., on Tuesday remaining=6, on Monday remaining=0.
    def remaining_days_in_week
      today = Date.today
      days_since_tuesday = (today.wday - 2) % 7 # Tuesday=0 .. Monday=6
      6 - days_since_tuesday
    end
  end
end
