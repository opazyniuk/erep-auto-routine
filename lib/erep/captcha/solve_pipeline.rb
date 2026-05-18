# frozen_string_literal: true

require "base64"
require_relative "icon_catalog"
require_relative "image_preprocessor"
require_relative "../template_matcher"
require_relative "../captcha_solver"
require_relative "../two_captcha_solver"

module Erep
  module Captcha
    class SolvePipeline
      def initialize(log_method: nil, work_dir: nil)
        @log = log_method
        @work_dir = work_dir || File.expand_path("../../../log", __dir__)
        @preprocessor = ImagePreprocessor.new(work_dir: @work_dir)
        @catalog = IconCatalog.new
        @matcher = TemplateMatcher.new(work_dir: @work_dir)
        @llm_solver = CaptchaSolver.new
        @two_captcha = TwoCaptchaSolver.new
      end

      # Paths from the last split (top, bottom, top_gray) — available after solve.
      attr_reader :last_split_paths

      # Solve a captcha image. Returns array of { x:, y:, score: } in strip order,
      # or empty array on failure.
      #
      # Strategy:
      #   1. Try template matching (free, fast, high-accuracy when templates exist)
      #   2. Fall back to 2Captcha (paid, reliable, also bootstraps new templates)
      def solve(full_image_path, icon_count: 3)
        # Step 1: Split image
        log "Splitting image..."
        parts = @preprocessor.split(full_image_path)
        @last_split_paths = parts

        # Step 2: Try template-based solving first
        coordinates = try_template_solve(parts, icon_count)
        if coordinates && coordinates.size == icon_count
          log "Template solver produced #{coordinates.size}/#{icon_count} coordinates — using template result"
          return coordinates
        end

        template_hits = coordinates&.size || 0
        log "Template solver: #{template_hits}/#{icon_count} — falling back to 2Captcha"

        # Step 3: Fall back to 2Captcha
        coordinates = try_two_captcha(full_image_path, icon_count)
        if coordinates && coordinates.size >= icon_count
          log "2Captcha solved: #{coordinates.size} coordinate(s)"
          return coordinates
        end

        log "All solvers failed"
        []
      end

      private

      # Attempt solving via LLM icon naming + template matching.
      # Returns array of coordinates (may be incomplete) or nil.
      def try_template_solve(parts, icon_count)
        return nil unless @llm_solver.backends_available?

        log "Identifying icons via LLM..."
        bottom_b64 = Base64.strict_encode64(File.binread(parts[:bottom]))
        icon_descriptions = @llm_solver.identify_icons(bottom_b64)

        if icon_descriptions.empty?
          log "LLM returned no icon names"
          return nil
        end
        log "LLM icons: #{icon_descriptions.join(', ')}"

        # Resolve LLM names to template names (dedup: each template used once)
        used_templates = []
        resolved = icon_descriptions.map do |desc|
          name = @catalog.resolve_name(desc)
          if name && used_templates.include?(name)
            log "  #{desc} → #{name} (DUPLICATE, treating as unknown)"
            name = nil
          else
            log "  #{desc} → #{name || 'UNKNOWN'}"
          end
          used_templates << name if name
          { description: desc, template_name: name }
        end

        known = resolved.select { |r| r[:template_name] }
        return nil if known.empty?

        # Template match known icons in scene (parallel)
        template_names = known.map { |r| r[:template_name] }
        log "Template matching #{template_names.size} icon(s)..."
        match_results = @matcher.match_icons(template_names, @catalog, parts[:top_gray])

        # Build coordinate map
        coord_map = {}
        match_results.each_with_index do |result, i|
          name = template_names[i]
          if result
            log "  #{name}: (#{result[:x]}, #{result[:y]}) score=#{result[:score].round(4)}"
            coord_map[name] = result
          else
            log "  #{name}: no match"
          end
        end

        # Assemble in strip order
        coordinates = resolved.map do |r|
          coord_map[r[:template_name]] if r[:template_name]
        end

        # Only return if ALL icons matched (partial results aren't useful)
        matched = coordinates.compact
        if matched.size == icon_count
          validate(matched)
        else
          log "Template match incomplete: #{matched.size}/#{icon_count}"
          nil
        end
      end

      # Solve via 2Captcha human workers.
      def try_two_captcha(full_image_path, icon_count)
        unless @two_captcha.available?
          log "2Captcha: no API key (set TWO_CAPTCHA_API_KEY)"
          return nil
        end

        image_b64 = Base64.strict_encode64(File.binread(full_image_path))
        coordinates = @two_captcha.solve(
          image_b64,
          min_clicks: icon_count,
          log: method(:log)
        )
        return nil unless coordinates

        # 2Captcha returns coordinates for the full image (400x230).
        # Scene is top 200px — coordinates should already be in scene area.
        # Validate bounds and add score marker.
        coordinates.map { |c| c.merge(score: 1.0, source: :two_captcha) }
                   .then { |cs| validate(cs) }
      end

      def validate(coordinates)
        coordinates.select do |c|
          in_bounds = c[:x].between?(0, 400) && c[:y].between?(0, 200)
          unless in_bounds
            log "  Rejected (#{c[:x]}, #{c[:y]}): out of bounds"
          end
          in_bounds
        end
      end

      def log(msg)
        @log&.call("[Pipeline] #{msg}")
      end
    end
  end
end
