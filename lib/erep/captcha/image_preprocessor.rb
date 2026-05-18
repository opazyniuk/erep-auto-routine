# frozen_string_literal: true

module Erep
  module Captcha
    class ImagePreprocessor
      # Full captcha: 400x230. Top 200px = scene, bottom 30px = icon strip.
      SCENE_HEIGHT = 200
      STRIP_HEIGHT = 30
      IMAGE_WIDTH  = 400

      def initialize(work_dir: nil)
        @work_dir = work_dir || File.expand_path("../../../log", __dir__)
        Dir.mkdir(@work_dir) unless Dir.exist?(@work_dir)
      end

      # Split full captcha into scene + strip + grayscale scene.
      # Returns { top: path, bottom: path, top_gray: path }
      def split(full_image_path)
        base = File.basename(full_image_path, ".*")
        top      = File.join(@work_dir, "#{base}_top.png")
        bottom   = File.join(@work_dir, "#{base}_bot.png")
        top_gray = File.join(@work_dir, "#{base}_top_gray.png")

        system("magick", full_image_path,
               "-crop", "#{IMAGE_WIDTH}x#{SCENE_HEIGHT}+0+0", "+repage", top)
        system("magick", full_image_path,
               "-crop", "#{IMAGE_WIDTH}x#{STRIP_HEIGHT}+0+#{SCENE_HEIGHT}",
               "+repage", "-trim", "+repage", bottom)
        system("magick", top,
               "-colorspace", "Gray", "-contrast-stretch", "2%x2%", top_gray)

        { top: top, bottom: bottom, top_gray: top_gray }
      end
    end
  end
end
