# frozen_string_literal: true

require "forwardable"
require_relative "browser/session"
require_relative "browser/auth"
require_relative "browser/verification"
require_relative "browser/training"
require_relative "browser/shop"
require_relative "browser/boosters"
require_relative "browser/battlefield"
require_relative "browser/deployment"
require_relative "browser/challenges"
require_relative "browser/travel"

module Erep
  # Facade over the browser session and the domain services that drive
  # eRepublik. Composes a Session (Chrome/CDP + Cloudflare + page primitives)
  # with one service per concern and forwards each public action to its owner.
  class Browser
    extend Forwardable

    BASE_URL = "https://www.erepublik.com"

    def initialize(log_file: nil)
      @session = Session.new(log_file: log_file)

      @auth = Auth.new(@session)
      @verification = Verification.new(@session)
      @training = Training.new(@session)
      @shop = Shop.new(@session)
      @boosters = Boosters.new(@session)
      @battlefield = Battlefield.new(@session)
      @deployment = Deployment.new(@session, @verification)
      @challenges = Challenges.new(@session)
      @travel = Travel.new(@session)
    end

    def_delegators :@session, :browser, :go_to, :quit, :kill!
    def_delegators :@auth, :login
    def_delegators :@verification, :handle_verification
    def_delegators :@training, :train, :buy_pro_training_contract
    def_delegators :@shop, :collect_vip_points, :purchase_weekly_energy_bars, :buy_gold
    def_delegators :@boosters, :ensure_damage_booster
    def_delegators :@battlefield, :battle_zone_active?, :read_battle_score, :read_wall_state,
                   :fetch_campaigns, :fetch_battle_stats, :analyze_round_fighters,
                   :fetch_account_info, :infantry_kit_active?, :read_fuel_balance, :read_energy
    def_delegators :@deployment, :deploy, :switch_side
    def_delegators :@challenges, :collect_daily_challenge, :collect_weekly_challenge
    def_delegators :@travel, :travel_home
  end

  class LoginError < StandardError; end
  class TrainError < StandardError; end
  class FightError < StandardError; end
end
