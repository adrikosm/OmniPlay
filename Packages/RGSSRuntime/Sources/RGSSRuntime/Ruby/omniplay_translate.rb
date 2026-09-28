# OmniPlay: an MTool text dictionary ({"original": "translation"}) applied to RPG Maker XP/VX/VX Ace games.
#
# Preload scripts run before the game's own, so its windows do not exist yet to hook. Every text a game shows comes
# out of its data files, though (event text and choices in maps and common events, names and descriptions in the
# database), and all of those go through load_data: each loaded object's strings are matched against the dictionary
# and replaced in place. Written for Ruby 1.8, 1.9 and 3.1; the JSON reader is the state bridge's (loaded first).

module OmniPlay
  module Translation
    module_function

    def load(path)
      @table = nil
      data = File.open(path, "rb") { |f| f.read }
      data = data[3..-1] if data[0, 3] == "\xEF\xBB\xBF"
      table = OmniPlay::Bridge.parse(data)
      @table = table if table.is_a?(Hash) && !table.empty?
    rescue Exception
      @table = nil
    end

    def table
      @table
    end

    def lookup(text)
      found = @table[text]
      return found if found
      return nil unless text.index("\n")
      lines = text.split("\n", -1)
      out = lines.map { |line| @table[line] || line }
      out == lines ? nil : out.join("\n")
    end

    # The shared pool's CJK font (TRANS-005). The bundled default, Liberation, has no Chinese, Japanese or Korean.
    CJK_FONT = "WenQuanYi Micro Hei"

    # True when the translations are written in Chinese, Japanese or Korean (judged on up to 200 of them).
    def cjk?
      @table.values.first(200).any? do |text|
        begin
          text.is_a?(String) && text.unpack("U*").any? { |c| (c >= 0x3040 && c <= 0x9FFF) || (c >= 0xAC00 && c <= 0xD7A3) }
        rescue Exception
          false
        end
      end
    end

    # Puts the CJK font first in the default font list, and keeps it first when the game sets its own default later.
    def prefer_cjk_font
      class << Font
        alias_method :omniplay_translation_default_name_set, :default_name=

        def default_name=(names)
          list = names.is_a?(Array) ? names.dup : [names]
          list.unshift(OmniPlay::Translation::CJK_FONT) unless list.include?(OmniPlay::Translation::CJK_FONT)
          omniplay_translation_default_name_set(list)
        end
      end
      Font.default_name = Font.default_name
    end

    # Strings are replaced in place so that references elsewhere see the translation too. Bitmaps, tables and other
    # engine objects hold no text and are skipped; a visited set stops cycles.
    def walk(object, seen = {})
      return if object.nil? || seen[object.object_id]
      seen[object.object_id] = true
      case object
      when String
        found = lookup(object)
        object.replace(found) if found && !object.frozen?
      when Array
        object.each { |item| walk(item, seen) }
      when Hash
        object.each_value { |item| walk(item, seen) }
      when Numeric, Symbol, TrueClass, FalseClass
        nil
      else
        return if defined?(Bitmap) && object.is_a?(Bitmap)
        return if defined?(Table) && object.is_a?(Table)
        object.instance_variables.each { |name| walk(object.instance_variable_get(name), seen) }
      end
    end
  end
end

OmniPlay::Translation.load("__DICTIONARY__")
if OmniPlay::Translation.table
  begin
    OmniPlay::Translation.prefer_cjk_font if OmniPlay::Translation.cjk?
  rescue Exception
  end
  module Kernel
    alias_method :omniplay_translation_load_data, :load_data

    def load_data(*args)
      data = omniplay_translation_load_data(*args)
      begin
        OmniPlay::Translation.walk(data)
      rescue Exception
      end
      data
    end
  end
end
