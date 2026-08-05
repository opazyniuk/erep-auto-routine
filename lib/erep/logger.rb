# frozen_string_literal: true

module Erep
  # Timestamped line logger. Writes to the given IO (a log file) or stdout when
  # none is provided. `indent` sets the gap after the timestamp, so nested browser
  # lines can sit visually under the top-level session lines that share the file.
  class Logger
    SEPARATOR = "=" * 60

    def initialize(io = nil, indent: " ")
      @io = io
      @indent = indent
    end

    def log(msg)
      line = "[#{Time.now.strftime('%Y-%m-%d %H:%M:%S')}]#{@indent}#{msg}"
      if @io
        @io.puts(line)
        @io.flush
      else
        puts line
      end
    end

    def separator
      log(SEPARATOR)
    end
  end
end
