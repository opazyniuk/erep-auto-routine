# frozen_string_literal: true

module Erep
  class FuelBudget
    attr_reader :fuel_left, :available_today

    def initialize(fuel_left:, now: Time.now)
      @fuel_left = fuel_left
      @now = now
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
    # The "fight day" rolls at 10:00 Kyiv time; before 10:00 we're still in
    # the previous day's block. Week resets Tue 10:00.
    # Block 0 = Tue 10:00 – Wed 09:59 (remaining=6) ... Block 6 = Mon 10:00 – Tue 09:59 (remaining=0).
    def remaining_days_in_week
      effective_wday = @now.hour < 10 ? (@now.wday - 1) % 7 : @now.wday
      days_since_tuesday = (effective_wday - 2) % 7 # Tuesday=0 .. Monday=6
      6 - days_since_tuesday
    end
  end
end
