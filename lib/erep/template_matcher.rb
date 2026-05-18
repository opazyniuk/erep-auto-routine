# frozen_string_literal: true

module Erep
  # Pure edge-detection + NCC matching engine.
  # Icon catalog and name resolution live in Captcha::IconCatalog.
  class TemplateMatcher
    MIN_SCORE = 0.8

    def initialize(work_dir: nil)
      @work_dir = work_dir || File.expand_path("../../log", __dir__)
    end

    # Match specific templates (by name) against the scene in parallel.
    # Pre-computes scene edge once, spawns concurrent magick processes.
    # Returns array of { name:, x:, y:, score: } in the same order as icon_names.
    # Entries are nil for icons that failed to match.
    def match_icons(icon_names, catalog, scene_gray_path)
      scene_edge = tmp("scene_edge")
      system("magick", scene_gray_path, "-edge", "2", scene_edge)

      # Prepare edge images for each template
      jobs = icon_names.filter_map do |name|
        tpl = catalog.template_path(name)
        next unless File.exist?(tpl)

        template_edge = tmp("tmpl_edge_#{name}")
        match_output = tmp("match_out_#{name}")
        system("magick", tpl, "-edge", "2", template_edge)

        { name: name, template: tpl, template_edge: template_edge,
          match_output: match_output }
      end

      # Spawn all NCC matches in parallel
      jobs.each do |job|
        rd, wr = IO.pipe
        job[:pid] = spawn(
          "magick", "compare", "-metric", "NCC", "-subimage-search",
          scene_edge, job[:template_edge], job[:match_output],
          out: "/dev/null", err: wr
        )
        wr.close
        job[:reader] = rd
      end

      # Collect results
      results = {}
      jobs.each do |job|
        Process.wait(job[:pid])
        raw = job[:reader].read
        job[:reader].close
        parsed = parse_ncc_result(raw, job[:template])
        results[job[:name]] = parsed&.merge(name: job[:name])
        cleanup(job[:template_edge], job[:match_output])
      end

      cleanup(scene_edge)

      # Return in original order
      icon_names.map { |name| results[name] }
    end

    # Match a single template against the scene (synchronous).
    def match_in_scene(template_path, scene_gray_path)
      scene_edge = tmp("scene_edge")
      template_edge = tmp("tmpl_edge")
      match_output = tmp("match_out")

      begin
        system("magick", scene_gray_path, "-edge", "2", scene_edge)
        system("magick", template_path, "-edge", "2", template_edge)

        result = `magick compare -metric NCC -subimage-search "#{scene_edge}" "#{template_edge}" "#{match_output}" 2>&1`
        parse_ncc_result(result, template_path)
      ensure
        cleanup(scene_edge, template_edge, match_output)
      end
    end

    private

    def parse_ncc_result(result, template_path)
      return nil unless result =~ /@\s*(\d+),(\d+)\s*\[([.\deE+-]+)\]/

      x = $1.to_i
      y = $2.to_i
      score = $3.to_f
      return nil if score < MIN_SCORE

      tw, th = template_dimensions(template_path)
      { x: x + tw / 2, y: y + th / 2, score: score }
    end

    def template_dimensions(path)
      info = `magick identify -format "%w %h" "#{path}" 2>/dev/null`.strip
      w, h = info.split.map(&:to_i)
      [w, h]
    end

    def tmp(label)
      File.join(@work_dir, "#{label}_#{$$}.png")
    end

    def cleanup(*files)
      files.each { |f| File.delete(f) rescue nil }
    end
  end
end
