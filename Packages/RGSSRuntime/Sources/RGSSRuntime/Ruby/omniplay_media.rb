# -*- coding: utf-8 -*-
# OmniPlay: media mkxp-z cannot decode, converted before launch into the Generated layer (mounted ahead of the game)
# under the same path with a new extension: movies to Theora (.ogv), audio to Vorbis (.ogg), images to PNG. Games
# name a file by its old extension or by none at all ("Audio/BGM/Battle1"); both are mapped onto the converted file.
#
# RGSSRuntime fills in the table (game-relative source, lower-cased => converted file) when it prepares the session.
# Written for Ruby 1.8, 1.9 and 3.1 alike.

module OmniPlayMedia
  TABLE = __TABLE__

  module_function

  def map(name)
    return name unless name.is_a?(String) && !TABLE.empty?

    TABLE[name.gsub("\\", "/").sub(%r{\A(\./)+}, "").downcase] || name
  end
end

unless OmniPlayMedia::TABLE.empty?
  if defined?(Graphics)
    class << Graphics
      if method_defined?(:play_movie)
        alias_method :_omniplay_play_movie, :play_movie unless method_defined?(:_omniplay_play_movie)

        def play_movie(name, *args)
          _omniplay_play_movie(OmniPlayMedia.map(name), *args)
        end
      end
    end
  end

  if defined?(Audio)
    class << Audio
      [:bgm_play, :bgs_play, :me_play, :se_play].each do |m|
        next unless method_defined?(m)

        original = "_omniplay_#{m}"
        alias_method original, m unless method_defined?(original)
        define_method(m) { |name, *args| send(original, OmniPlayMedia.map(name), *args) }
      end
    end
  end

  if defined?(Bitmap)
    class Bitmap
      alias_method :_omniplay_initialize, :initialize unless private_method_defined?(:_omniplay_initialize)

      def initialize(*args)
        args[0] = OmniPlayMedia.map(args[0]) if args[0].is_a?(String)
        _omniplay_initialize(*args)
      end
    end
  end
end
