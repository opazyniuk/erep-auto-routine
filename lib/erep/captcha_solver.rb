# frozen_string_literal: true

require "net/http"
require "json"
require "base64"
require "uri"

module Erep
  class CaptchaSolver
    IDENTIFY_PROMPT = <<~PROMPT
      This image shows a row of small dark icons/symbols on a white background.
      Describe each icon from left to right. For each icon, give a short unique name
      that clearly distinguishes it from the others (e.g. "snowflake", "hourglass",
      "person with crosshair", "circular arrows", "mountain peaks", "compass rose").
      Return ONLY a comma-separated list, nothing else.
    PROMPT

    LOCATE_PROMPT = <<~PROMPT
      This 400x200 pixel photo has semi-transparent white/gray ICON OVERLAYS floating on top of the scene.
      Each overlay is roughly 40-60 pixels wide, with a slight square background behind it.

      I need you to find these specific icons IN THIS EXACT ORDER: %{icons}

      For EACH icon listed above:
      1. Scan the entire image carefully to find the matching overlay
      2. Return the CENTER (x, y) pixel coordinates of that overlay
      3. Keep the same order as my list — do NOT reorder by position

      Each icon appears exactly ONCE in the image. Every coordinate must be different.
      Return ONLY a JSON array with one object per icon. No explanation.
      Example: [{"x":350,"y":30},{"x":45,"y":100},{"x":190,"y":140}]
    PROMPT

    def initialize
      @backends = detect_backends
    end

    # Identify icons from the bottom strip image.
    # Returns array of icon name strings, left-to-right.
    def identify_icons(image_b64)
      text = call_with_fallback(IDENTIFY_PROMPT, image_b64)
      return [] unless text

      text.strip.split(/,\s*/).map(&:strip).reject(&:empty?)
    end

    # Last-resort: ask LLM to locate icons in the scene.
    # Returns array of { "x" => Int, "y" => Int }.
    def locate_icons(image_b64, icon_names)
      prompt = LOCATE_PROMPT % { icons: icon_names.join(", ") }
      text = call_with_fallback(prompt, image_b64)
      return [] unless text

      parse_coordinates(text)
    end

    # Run locate_icons N times, return consensus coordinates.
    # For each icon slot, clusters results across runs and picks the
    # centroid of the largest cluster. Filters out hallucinated outliers.
    def locate_icons_consensus(image_b64, icon_names, runs: 3, radius: 40, log: nil)
      all_runs = []
      runs.times do |i|
        coords = locate_icons(image_b64, icon_names)
        log&.call("  Consensus run #{i + 1}/#{runs}: #{coords.size}/#{icon_names.size} coords")
        # Pad short results with nil so slot indices stay aligned
        padded = icon_names.each_index.map { |j| coords[j] }
        all_runs << padded
      end

      # For each icon slot, cluster non-nil points across runs
      icon_names.each_index.map do |slot|
        points = all_runs.map { |run| run[slot] }.compact
        if points.empty?
          log&.call("  Slot #{slot} (#{icon_names[slot]}): no data")
          next nil
        end
        best = cluster_centroid(points, radius)
        log&.call("  Slot #{slot} (#{icon_names[slot]}): consensus (#{best['x']},#{best['y']}) from #{points.size} points")
        best
      end
    end

    def backends_available?
      @backends.any?
    end

    private

    # Try each available backend in order until one succeeds.
    # Order: Gemini (fast/free) → Anthropic (accurate) → Ollama (local)
    def call_with_fallback(prompt, image_b64)
      @backends.each do |backend|
        result = send(:"call_#{backend}", prompt, image_b64)
        return result if result && !result.empty?
      rescue => e
        next
      end
      nil
    end

    def detect_backends
      # Explicit override pins to a single backend
      if (override = ENV["CAPTCHA_BACKEND"])
        return [override.to_sym]
      end

      backends = []
      backends << :gemini if ENV["GEMINI_API_KEY"]
      backends << :anthropic if ENV["ANTHROPIC_API_KEY"]
      backends << :ollama if ollama_available?
      backends
    end

    def ollama_available?
      Net::HTTP.get(URI("http://localhost:11434/api/tags"))
      true
    rescue StandardError
      false
    end

    # ── Backend callers ─────────────────────────────────────────

    def call_gemini(prompt, image_b64)
      key = ENV.fetch("GEMINI_API_KEY")
      uri = URI("https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=#{key}")
      body = {
        contents: [{
          parts: [
            { inlineData: { mimeType: "image/png", data: image_b64 } },
            { text: prompt }
          ]
        }]
      }
      response = post_json(uri, body)
      response.dig("candidates", 0, "content", "parts", 0, "text")
    end

    def call_ollama(prompt, image_b64)
      uri = URI("http://localhost:11434/api/chat")
      body = {
        model: ENV.fetch("OLLAMA_MODEL", "llama3.2-vision:11b"),
        stream: false,
        messages: [{ role: "user", content: prompt, images: [image_b64] }]
      }
      response = post_json(uri, body)
      response["error"] ? nil : response.dig("message", "content")
    end

    def call_anthropic(prompt, image_b64)
      key = ENV.fetch("ANTHROPIC_API_KEY")
      uri = URI("https://api.anthropic.com/v1/messages")

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      request = Net::HTTP::Post.new(uri.path)
      request["Content-Type"] = "application/json"
      request["x-api-key"] = key
      request["anthropic-version"] = "2023-06-01"
      request.body = {
        model: "claude-sonnet-4-20250514",
        max_tokens: 512,
        messages: [{
          role: "user",
          content: [
            { type: "image", source: { type: "base64", media_type: "image/png", data: image_b64 } },
            { type: "text", text: prompt }
          ]
        }]
      }.to_json

      response = JSON.parse(http.request(request).body)
      response.dig("content", 0, "text")
    end

    # ── Helpers ───────────────────────────────────────────────────

    def post_json(uri, body)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.read_timeout = 300
      http.open_timeout = 10

      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request.body = body.to_json

      JSON.parse(http.request(request).body)
    rescue Net::ReadTimeout, Net::OpenTimeout => e
      { "error" => "timeout: #{e.message}" }
    end

    def parse_coordinates(text)
      match = text.match(/\[.*?\]/m)
      return [] unless match

      coords = JSON.parse(match[0])
      coords.select { |c| c["x"] && c["y"] }
    rescue JSON::ParserError
      []
    end

    # Given an array of {"x"=>Int,"y"=>Int} points, find the largest cluster
    # within `radius` pixels and return its centroid.
    def cluster_centroid(points, radius)
      return nil if points.empty?
      return points.first if points.size == 1

      # For each point, count how many other points are within radius
      best_group = []
      points.each do |anchor|
        group = points.select do |p|
          Math.hypot(p["x"] - anchor["x"], p["y"] - anchor["y"]) <= radius
        end
        best_group = group if group.size > best_group.size
      end

      # Centroid of the largest cluster
      avg_x = best_group.sum { |p| p["x"] } / best_group.size
      avg_y = best_group.sum { |p| p["y"] } / best_group.size
      { "x" => avg_x, "y" => avg_y }
    end
  end
end
