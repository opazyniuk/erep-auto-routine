# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module Erep
  # Solves captchas via 2Captcha's CoordinatesTask API.
  # Sends the full captcha image with click instructions,
  # polls until solved, returns ordered coordinates.
  class TwoCaptchaSolver
    API_BASE = "https://api.2captcha.com"
    POLL_INTERVAL = 5 # seconds
    MAX_POLLS = 60 # 5 minutes max wait

    def initialize(api_key: ENV["TWO_CAPTCHA_API_KEY"])
      @api_key = api_key
    end

    def available?
      !@api_key.nil? && !@api_key.empty?
    end

    # Solve a captcha image. Returns array of { x:, y: } in click order,
    # or nil on failure.
    #
    # image_b64 - Base64-encoded PNG of the full captcha (400x230)
    # min_clicks - minimum number of clicks required
    # comment - instruction text shown to the human worker
    def solve(image_b64, min_clicks: 3, comment: nil, log: nil)
      comment ||= default_comment(min_clicks)

      # Step 1: Submit task
      log&.call("Submitting to 2Captcha (CoordinatesTask, minClicks=#{min_clicks})...")
      task_id = create_task(image_b64, min_clicks: min_clicks, comment: comment)

      unless task_id
        log&.call("2Captcha: failed to create task")
        return nil
      end
      log&.call("2Captcha: task created (id=#{task_id}), polling...")

      # Step 2: Poll for result
      MAX_POLLS.times do |i|
        sleep POLL_INTERVAL
        result = get_task_result(task_id)

        case result[:status]
        when :ready
          coords = result[:coordinates]
          log&.call("2Captcha: solved! #{coords.size} coordinate(s) in #{(i + 1) * POLL_INTERVAL}s")
          return coords
        when :processing
          log&.call("2Captcha: still processing... (#{(i + 1) * POLL_INTERVAL}s)") if (i + 1) % 6 == 0
        when :error
          log&.call("2Captcha: error — #{result[:message]}")
          return nil
        end
      end

      log&.call("2Captcha: timeout after #{MAX_POLLS * POLL_INTERVAL}s")
      nil
    end

    private

    def default_comment(min_clicks)
      "Click on the icons in the image in the same order " \
        "as they appear in the bottom strip (left to right). " \
        "Click exactly #{min_clicks} icons."
    end

    def create_task(image_b64, min_clicks:, comment:)
      body = {
        clientKey: @api_key,
        task: {
          type: "CoordinatesTask",
          body: image_b64,
          comment: comment,
          minClicks: min_clicks,
          maxClicks: min_clicks
        }
      }

      response = post_json("#{API_BASE}/createTask", body)
      return nil unless response

      if response["errorId"].to_i > 0
        return nil
      end

      response["taskId"]
    end

    def get_task_result(task_id)
      body = {
        clientKey: @api_key,
        taskId: task_id
      }

      response = post_json("#{API_BASE}/getTaskResult", body)
      return { status: :error, message: "network error" } unless response

      if response["errorId"].to_i > 0
        return { status: :error, message: response["errorDescription"] || response["errorCode"] }
      end

      if response["status"] == "ready"
        raw_coords = response.dig("solution", "coordinates") || []
        coordinates = raw_coords.map { |c| { x: c["x"].to_i, y: c["y"].to_i } }
        { status: :ready, coordinates: coordinates }
      else
        { status: :processing }
      end
    end

    def post_json(url, body)
      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 10
      http.read_timeout = 30

      request = Net::HTTP::Post.new(uri.path)
      request["Content-Type"] = "application/json"
      request.body = body.to_json

      JSON.parse(http.request(request).body)
    rescue StandardError
      nil
    end
  end
end