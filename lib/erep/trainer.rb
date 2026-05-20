# frozen_string_literal: true

require "date"
require_relative "browser"

module Erep
  class Trainer
    LOG_FILE = File.open(File.expand_path("../../log/train.log", __dir__), "a")

    def initialize(email:, password:)
      @email = email
      @password = password
    end

    def run
      log separator
      log "Starting daily routine"
      browser = Browser.new(log_file: LOG_FILE)

      browser.login(@email, @password)

      train_result = safe_step("Training") { browser.train }

      pro_contract_result = if last_days_of_month?
                              safe_step("Pro Training Contract") { browser.buy_pro_training_contract }
                            else
                              :skipped
                            end

      vip_result = safe_step("VIP collection") { browser.collect_vip_points }

      energy_bars_result = safe_step("Weekly energy bars") { browser.purchase_weekly_energy_bars }

      gold_result = safe_step("Daily gold buy") { browser.buy_gold }

      log "Done | train=#{train_result} pro_contract=#{pro_contract_result} vip=#{vip_result} energy_bars=#{energy_bars_result} gold=#{gold_result}"
      log separator
      train_result != :error
    rescue => e
      log "FAILED | #{e.message}"
      log e.backtrace.first(5).join("\n")
      log separator
      false
    ensure
      browser&.quit
    end

    private

    def safe_step(name)
      yield
    rescue => e
      log "#{name} failed: #{e.message}"
      log e.backtrace.first(3).join("\n")
      :error
    end

    def last_days_of_month?
      today = Date.today
      last_day = Date.new(today.year, today.month, -1)
      (last_day - today).to_i < 3
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
