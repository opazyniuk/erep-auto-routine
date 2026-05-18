# frozen_string_literal: true

require "fileutils"

module Erep
  module Captcha
    # Extracts new templates from successfully solved captchas.
    # After the server confirms a correct solve, crops 50x50 grayscale regions
    # at the clicked coordinates and saves unknown icons as new templates.
    class TemplateExtractor
      def initialize(templates_dir: IconCatalog::TEMPLATES_DIR)
        @templates_dir = templates_dir
        @catalog = IconCatalog.new(templates_dir: templates_dir)
        @matcher = TemplateMatcher.new
      end

      # Extract templates from a solved captcha.
      # coordinates: array of { x:, y:, name: } (name may be nil for unknown icons)
      # scene_gray_path: path to the grayscale scene image
      def extract(scene_gray_path, coordinates)
        coordinates.each_with_index do |coord, i|
          name = coord[:name]
          x = coord[:x] - 25
          y = coord[:y] - 25

          # Clamp to image bounds
          x = [[x, 0].max, 350].min
          y = [[y, 0].max, 150].min

          region_path = "/tmp/extract_region_#{i}.png"
          system("magick", scene_gray_path, "-crop", "50x50+#{x}+#{y}", "+repage",
                 "-colorspace", "Gray", region_path)

          next unless File.exist?(region_path)

          if name && File.exist?(@catalog.template_path(name))
            # Known icon — check if this is a useful variant
            check_variant(name, region_path)
          else
            # Unknown icon — save as new template
            save_new_template(region_path, i)
          end

          File.delete(region_path) rescue nil
        end
      end

      private

      def check_variant(name, region_path)
        existing = @catalog.template_path(name)
        result = @matcher.match_in_scene(existing, region_path)

        # If score is moderate (different enough to be a variant but similar enough to be the same icon)
        if result && result[:score].between?(0.7, 0.95)
          variant_path = find_next_variant_path(name)
          FileUtils.cp(region_path, variant_path)
          warn "[TemplateExtractor] Saved variant: #{variant_path} (score=#{result[:score].round(3)} vs primary)"
        end
      end

      def save_new_template(region_path, index)
        # Check if this region matches any existing template
        best_match = nil
        best_score = 0

        @catalog.all_names.each do |name|
          tpl = @catalog.template_path(name)
          next unless File.exist?(tpl)

          result = @matcher.match_in_scene(tpl, region_path)
          if result && result[:score] > best_score
            best_score = result[:score]
            best_match = name
          end
        end

        if best_score >= 0.8
          warn "[TemplateExtractor] Region #{index} matches existing '#{best_match}' (score=#{best_score.round(3)}), skipping"
          return
        end

        # Genuinely new icon — save with timestamp name
        new_name = "unknown_#{Time.now.strftime('%Y%m%d_%H%M%S')}_#{index}"
        new_path = File.join(@templates_dir, "#{new_name}.png")
        FileUtils.cp(region_path, new_path)
        warn "[TemplateExtractor] NEW icon template saved: #{new_path}"
      end

      def find_next_variant_path(name)
        i = 2
        loop do
          path = File.join(@templates_dir, "#{name}_v#{i}.png")
          return path unless File.exist?(path)
          i += 1
        end
      end
    end
  end
end
