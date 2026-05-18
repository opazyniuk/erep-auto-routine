# frozen_string_literal: true

module Erep
  module Captcha
    class IconCatalog
      TEMPLATES_DIR = File.expand_path("../../../test/fixtures/captchas/templates", __dir__)

      # All known icon types. Each has a 50x50 grayscale template.
      ICONS = %w[
        bomb
        circular_arrows
        cross_star
        hourglass
        mountains
        person_target
        snowflake
      ].freeze

      # Map LLM-generated descriptions to canonical icon names.
      # Scored by word overlap, with substring fallback.
      NAME_ALIASES = {
        "bomb" => "bomb", "explosive" => "bomb", "grenade" => "bomb",
        "dynamite" => "bomb", "mine" => "bomb", "rocket" => "bomb",
        "missile" => "bomb", "firecracker" => "bomb", "firework" => "bomb",
        "snowflake" => "snowflake", "snow" => "snowflake", "ice" => "snowflake",
        "crystal" => "snowflake", "frost" => "snowflake",
        "cross" => "cross_star", "star" => "cross_star", "sparkle" => "cross_star",
        "x" => "cross_star", "asterisk" => "cross_star", "spark" => "cross_star",
        "burst" => "cross_star", "explosion" => "cross_star",
        "person" => "person_target",
        "man" => "person_target", "figure" => "person_target",
        "crosshair" => "person_target",
        "person with target" => "person_target", "person target" => "person_target",
        "human" => "person_target", "silhouette" => "person_target",
        "circular" => "circular_arrows", "arrows" => "circular_arrows",
        "refresh" => "circular_arrows", "rotate" => "circular_arrows",
        "cycle" => "circular_arrows", "sync" => "circular_arrows",
        "reload" => "circular_arrows", "loop" => "circular_arrows",
        "recycle" => "circular_arrows", "target" => "circular_arrows",
        "bullseye" => "circular_arrows",
        "concentric" => "circular_arrows", "rings" => "circular_arrows",
        "hourglass" => "hourglass", "timer" => "hourglass", "sand" => "hourglass",
        "clock" => "hourglass", "time" => "hourglass",
        "mountain" => "mountains", "mountains" => "mountains", "peaks" => "mountains",
        "triangle" => "mountains", "hill" => "mountains", "hills" => "mountains"
      }.freeze

      def initialize(templates_dir: TEMPLATES_DIR)
        @templates_dir = templates_dir
        validate_templates!
      end

      # All template names: hardcoded + dynamically extracted ones.
      def all_names
        static = ICONS.dup
        dynamic = Dir.glob(File.join(@templates_dir, "*.png"))
                     .map { |f| File.basename(f, ".png") }
                     .reject { |n| static.include?(n) || n.include?("_v") }
        static + dynamic
      end

      def template_path(name)
        File.join(@templates_dir, "#{name}.png")
      end

      # Resolve an LLM-generated description to a canonical icon name.
      # Uses word-overlap scoring with word-boundary substring fallback.
      def resolve_name(description)
        desc = description.to_s.downcase.strip
        return desc if ICONS.include?(desc)

        desc_words = desc.split(/[\s,_-]+/)
        best_match = nil
        best_score = 0

        NAME_ALIASES.each do |keyword, template|
          kw_words = keyword.split(/[\s,_-]+/)
          overlap = (desc_words & kw_words).size
          score = overlap.to_f / [kw_words.size, 1].max

          # Substring fallback: only for keywords >= 4 chars, must match a whole word
          if keyword.length >= 4 && desc_words.any? { |w| w.include?(keyword) }
            score = [score, 0.5].max
          end

          if score > best_score
            best_score = score
            best_match = template
          end
        end

        best_score >= 0.5 ? best_match : nil
      end

      private

      def validate_templates!
        ICONS.each do |name|
          path = template_path(name)
          warn "[IconCatalog] Missing template: #{path}" unless File.exist?(path)
        end
      end
    end
  end
end
