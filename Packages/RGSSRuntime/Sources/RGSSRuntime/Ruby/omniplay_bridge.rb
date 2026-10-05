# OmniPlay: typed state requests (the Game Tools, cheats and editors) for RPG Maker XP, VX and VX Ace.
#
# The host enqueues a JSON request; the engine hands it to OmniPlay::Bridge.handle on its own thread between frames
# (mkxp-z patch 0002), and the JSON returned here goes back to the host. The protocol is the one omniplay-state.js
# speaks for MV/MZ: {op: "list"|"get"|"set"|"metadata", ...}, targets {kind, id, prop, param, flag, ...}.
#
# Written for Ruby 1.8, 1.9 and 3.1 alike: no json library (1.8 has none), no ->, no key: syntax, s[i, 1] for chars.

module OmniPlay
  module Bridge
    module_function

    # ---- JSON, just enough for the protocol ----

    def parse(text)
      @s = text.to_s
      # Requests and dictionaries arrive as raw bytes; on 1.9+ they must read as UTF-8 to match the game's strings.
      @s = @s.dup.force_encoding("UTF-8") if @s.respond_to?(:force_encoding)
      @i = 0
      value
    end

    def ws
      @i += 1 while @i < @s.length && " \t\r\n".index(@s[@i, 1])
    end

    def value
      ws
      c = @s[@i, 1]
      if c == "{"
        @i += 1
        h = {}
        ws
        if @s[@i, 1] == "}"
          @i += 1
          return h
        end
        loop do
          ws
          k = string
          ws
          @i += 1 # :
          h[k] = value
          ws
          c = @s[@i, 1]
          @i += 1
          break if c == "}"
        end
        h
      elsif c == "["
        @i += 1
        a = []
        ws
        if @s[@i, 1] == "]"
          @i += 1
          return a
        end
        loop do
          a << value
          ws
          c = @s[@i, 1]
          @i += 1
          break if c == "]"
        end
        a
      elsif c == "\""
        string
      elsif @s[@i, 4] == "true"
        @i += 4
        true
      elsif @s[@i, 5] == "false"
        @i += 5
        false
      elsif @s[@i, 4] == "null"
        @i += 4
        nil
      else
        start = @i
        @i += 1 while @i < @s.length && "+-0123456789.eE".index(@s[@i, 1])
        n = @s[start...@i]
        n.index(".") || n.index("e") || n.index("E") ? n.to_f : n.to_i
      end
    end

    def string
      @i += 1 # opening quote
      out = ""
      while @i < @s.length
        c = @s[@i, 1]
        @i += 1
        break if c == "\""
        if c == "\\"
          e = @s[@i, 1]
          @i += 1
          case e
          when "n" then out << "\n"
          when "t" then out << "\t"
          when "r" then out << "\r"
          when "u"
            code = @s[@i, 4].to_i(16)
            @i += 4
            out << [code].pack("U")
          else out << e
          end
        else
          out << c
        end
      end
      out
    end

    def dump(v)
      case v
      when Hash then "{" + v.map { |k, x| dump(k.to_s) + ":" + dump(x) }.join(",") + "}"
      when Array then "[" + v.map { |x| dump(x) }.join(",") + "]"
      when String
        "\"" + v.gsub(/[\\"\x00-\x1f]/) { |m| m == "\\" ? "\\\\" : m == "\"" ? "\\\"" : format("\\u%04x", m.unpack("C")[0]) } + "\""
      when true then "true"
      when false then "false"
      when nil then "null"
      when Integer then v.to_s
      when Float then v.finite? ? v.to_s : dump(v.to_s) # JSON has no Infinity or NaN
      else dump(v.to_s)
      end
    end

    # ---- The game ----

    def vx?
      defined?(RPG::BaseItem) ? true : false
    end

    def ready?
      $game_party && $game_variables && $game_switches && $data_system ? true : false
    end

    def table(kind)
      kind == "weapon" ? $data_weapons : kind == "armor" ? $data_armors : $data_items
    end

    def item_count(kind, id)
      if vx?
        $game_party.item_number(table(kind)[id])
      else
        kind == "weapon" ? $game_party.weapon_number(id) : kind == "armor" ? $game_party.armor_number(id) : $game_party.item_number(id)
      end
    end

    def gain(kind, id, n)
      if vx?
        $game_party.gain_item(table(kind)[id], n)
      elsif kind == "weapon"
        $game_party.gain_weapon(id, n)
      elsif kind == "armor"
        $game_party.gain_armor(id, n)
      else
        $game_party.gain_item(id, n)
      end
    end

    # ---- Patches: named, typed behaviour changes for the cheat catalog (never code from the host) ----
    # noEncounters: VX/Ace keep $game_system.encounter_disabled, which is stored in saves; XP has no such flag, so
    # its encounter counter is held above zero for the session. noclip: the player's through flag.
    # debugMenu: setting it opens the game's own debug scene. godMode: actors' HP never drops and they are never
    # knocked out; every generation's damage ends in Game_Actor#hp= or state 1 (knockout), so those two are held.

    def no_encounters?
      if $game_system.respond_to?(:encounter_disabled)
        $game_system.encounter_disabled ? true : false
      else
        @no_encounters ? true : false
      end
    end

    def set_no_encounters(on)
      if $game_system.respond_to?(:encounter_disabled=)
        $game_system.encounter_disabled = on
      else
        @no_encounters = on
        return if @encounter_hooked
        @encounter_hooked = true
        Game_Player.class_eval do
          alias_method :omniplay_encounter_count, :encounter_count
          def encounter_count
            OmniPlay::Bridge.no_encounters? ? [omniplay_encounter_count, 1].max : omniplay_encounter_count
          end
        end
      end
    end

    # Everyone in the party, reserves included. XP keeps them in `actors`; VX `members`; VX Ace `all_members`
    # (its `members` is the battle line-up). Party scripts such as KGC_LargeParty narrow `members` to the battle
    # line-up on VX too, and can leave it empty, so `all_members` wins wherever a game defines it.
    def party_members
      return $game_party.all_members if $game_party.respond_to?(:all_members)
      $game_party.respond_to?(:members) ? $game_party.members : $game_party.actors
    end

    # Kept outside Game_Actor so Marshal saves cannot persist these session-only switches.
    def actor_god_mode?(id)
      return @god_actors[id] if @god_actors && @god_actors.has_key?(id)
      @god ? true : false
    end

    def god_mode?
      members = party_members
      !members.empty? && members.all? { |a| actor_god_mode?(a.id) }
    end

    def set_god_mode(on)
      hook_god_mode
      @god = on
      @god_actors = {}
    end

    def set_actor_god_mode(id, on)
      hook_god_mode
      @god_actors ||= {}
      @god_actors[id] = on
    end

    def hook_god_mode
      return if @god_hooked
      @god_hooked = true
      Game_Actor.class_eval do
        alias_method :omniplay_set_hp, :hp=
        def hp=(value)
          omniplay_set_hp(OmniPlay::Bridge.actor_god_mode?(id) ? [value, hp].max : value)
        end
        alias_method :omniplay_add_state, :add_state
        def add_state(state, *rest)
          death = respond_to?(:death_state_id) ? death_state_id : 1
          omniplay_add_state(state, *rest) unless OmniPlay::Bridge.actor_god_mode?(id) && state == death
        end
        if method_defined?(:die)
          alias_method :omniplay_die, :die
          def die
            omniplay_die unless OmniPlay::Bridge.actor_god_mode?(id)
          end
        end
      end
    end

    def read_patch(name)
      case name
      when "noEncounters" then no_encounters?
      when "noclip" then $game_player.instance_variable_get(:@through) ? true : false
      when "godMode" then god_mode?
      when "debugMenu"
        next_scene = defined?(SceneManager) ? SceneManager.scene : $scene
        defined?(Scene_Debug) && next_scene.is_a?(Scene_Debug) ? true : false
      else raise "unknown patch #{name}"
      end
    end

    def write_patch(name, on)
      case name
      when "noEncounters" then set_no_encounters(on)
      when "noclip" then $game_player.instance_variable_set(:@through, on)
      when "godMode" then set_god_mode(on)
      when "debugMenu"
        return unless on && defined?(Scene_Debug)
        if defined?(SceneManager)
          SceneManager.call(Scene_Debug)
        else
          $scene = Scene_Debug.new
        end
      else raise "unknown patch #{name}"
      end
    end

    def actor(id)
      a = $game_actors[id]
      raise "no actor #{id}" unless a
      a
    end

    def read(t)
      id = t["id"].to_i
      case t["kind"]
      when "patch" then read_patch(t["name"])
      when "variable" then $game_variables[id]
      when "switch" then $game_switches[id] ? true : false
      when "selfSwitch" then $game_self_switches[[t["map"].to_i, t["event"].to_i, t["key"].to_s]] ? true : false
      when "gold" then $game_party.gold
      when "item", "weapon", "armor" then item_count(t["kind"], id)
      when "partyMember" then party_members.map { |a| a.id }.include?(id)
      when "actor"
        a = actor(id)
        case t["prop"]
        when "hp" then a.hp
        when "mp" then a.respond_to?(:mp) ? a.mp : a.sp
        when "tp" then a.respond_to?(:tp) ? a.tp : 0
        when "level" then a.level
        when "exp" then a.exp
        when "name" then a.name
        when "godMode" then actor_god_mode?(id)
        else raise "unknown actor property #{t["prop"]}"
        end
      when "system"
        case t["flag"]
        when "saveEnabled" then !$game_system.save_disabled
        when "encounterEnabled" then !$game_system.encounter_disabled
        when "menuEnabled" then !$game_system.menu_disabled
        else raise "unknown flag #{t["flag"]}"
        end
      when "position" then { "map" => $game_map.map_id, "x" => $game_player.x, "y" => $game_player.y }
      else raise "unknown target #{t["kind"]}"
      end
    end

    def write(t, op, v)
      old = read(t)
      v = old.to_i + v.to_i if op == "add"
      v = !old if op == "toggle"
      id = t["id"].to_i
      case t["kind"]
      when "patch" then write_patch(t["name"], v ? true : false)
      when "variable" then $game_variables[id] = v.is_a?(Numeric) ? v.to_i : v
      when "switch" then $game_switches[id] = v ? true : false
      when "selfSwitch" then $game_self_switches[[t["map"].to_i, t["event"].to_i, t["key"].to_s]] = v ? true : false
      when "gold" then $game_party.gain_gold(v.to_i - $game_party.gold)
      when "item", "weapon", "armor" then gain(t["kind"], id, v.to_i - item_count(t["kind"], id))
      when "partyMember" then v ? $game_party.add_actor(id) : $game_party.remove_actor(id)
      when "actor"
        a = actor(id)
        case t["prop"]
        when "hp" then a.hp = v.to_i
        when "mp" then a.respond_to?(:mp=) ? a.mp = v.to_i : a.sp = v.to_i
        when "tp" then a.tp = v.to_i if a.respond_to?(:tp=)
        when "level" then a.respond_to?(:change_level) ? a.change_level(v.to_i, false) : a.level = v.to_i
        when "exp" then a.respond_to?(:change_exp) ? a.change_exp(v.to_i, false) : a.exp = v.to_i
        when "name" then a.name = v.to_s
        when "godMode" then set_actor_god_mode(id, v ? true : false)
        else raise "unknown actor property #{t["prop"]}"
        end
      when "system"
        case t["flag"]
        when "saveEnabled" then $game_system.save_disabled = !v
        when "encounterEnabled" then $game_system.encounter_disabled = !v
        when "menuEnabled" then $game_system.menu_disabled = !v
        end
      when "position" then $game_player.moveto(v["x"].to_i, v["y"].to_i)
      else raise "unknown target #{t["kind"]}"
      end
      $game_map.need_refresh = true if $game_map && $game_map.respond_to?(:need_refresh=)
      { "old" => old, "effective" => read(t) }
    end

    # ---- Freeze: values put back every frame, from a Graphics.update wrapper installed on the first freeze ----

    MAX_FROZEN = 32

    def frozen
      @frozen ||= {}
    end

    # Field by field: the host's JSON does not keep key order.
    def frozen_key(t)
      %w[kind id prop param flag map event key name].map { |k| t[k].to_s }.join("|")
    end

    def freeze_target(t, v)
      raise "only plain values can be frozen" if v.is_a?(Hash) || v.is_a?(Array) || v.nil?
      k = frozen_key(t)
      raise "at most #{MAX_FROZEN} values can be frozen" if !frozen.key?(k) && frozen.size >= MAX_FROZEN
      result = write(t, "set", v)
      # Held at what the game accepted (a capped value), so the hold does not fight the engine's own limits.
      frozen[k] = [t, result["effective"]]
      hook_frames
      result
    end

    def reapply_frozen
      return if @frozen.nil? || @frozen.empty?
      @frozen.keys.each do |k|
        t, v = @frozen[k]
        begin
          write(t, "set", v) if read(t) != v
        rescue Exception
          @frozen.delete(k)
        end
      end
    end

    def hook_frames
      return if @hooked
      @hooked = true
      class << Graphics
        alias_method :omniplay_update_without_freeze, :update
        def update(*args)
          OmniPlay::Bridge.reapply_frozen
          omniplay_update_without_freeze(*args)
        end
      end
    end

    def label(name, fallback)
      name.to_s.strip.empty? ? fallback : name.to_s
    end

    def entries(category, query)
      out = []
      q = query.to_s.downcase
      add = lambda do |target, name|
        next if !q.empty? && !name.downcase.include?(q) && target["id"].to_s != q
        out << { "target" => target, "name" => name, "value" => read(target), "editable" => true }
      end
      case category
      when "variables"
        (1...$data_system.variables.size).each { |i| add.call({ "kind" => "variable", "id" => i }, label($data_system.variables[i], "Variable #{i}")) }
      when "switches"
        (1...$data_system.switches.size).each { |i| add.call({ "kind" => "switch", "id" => i }, label($data_system.switches[i], "Switch #{i}")) }
      when "items", "weapons", "armors"
        kind = category.chop
        t = table(kind)
        (1...t.size).each { |i| add.call({ "kind" => kind, "id" => i }, t[i].name) if t[i] && !t[i].name.to_s.empty? }
      when "actors"
        members = party_members
        members.each do |a|
          %w[hp mp level exp].each { |p| add.call({ "kind" => "actor", "id" => a.id, "prop" => p }, "#{a.name} #{p.upcase}") }
        end
      when "system"
        add.call({ "kind" => "gold" }, "Gold")
        add.call({ "kind" => "system", "flag" => "saveEnabled" }, "saveEnabled")
        add.call({ "kind" => "position" }, "Player position")
      else
        raise "category not available here: #{category}"
      end
      out
    end

    # Save slots through the game's own code (SAVE-009), so its save format stays its own business. VX Ace has
    # DataManager; XP and VX write through their save scenes' read_save_data/write_save_data.
    def slot_index(file)
      number = file[/(\d+)/, 1]
      raise ArgumentError, "no slot number in #{file}" unless number
      number.to_i - 1
    end

    def load_slot(file)
      if defined?(DataManager)
        return { "error" => "the game could not load #{file}" } unless DataManager.load_game(slot_index(file))
        $game_system.on_after_load if $game_system.respond_to?(:on_after_load)
        SceneManager.goto(Scene_Map) if defined?(SceneManager)
      elsif defined?(Scene_Load)
        File.open(file, "rb") { |f| Scene_Load.new.send(:read_save_data, f) }
        $scene = Scene_Map.new
      elsif defined?(Scene_File)
        File.open(file, "rb") { |f| Scene_File.new(false, false, false).send(:read_save_data, f) }
        $scene = Scene_Map.new
      else
        return { "error" => "this game has no save code OmniPlay knows" }
      end
      {}
    end

    def save_slot(file)
      # Saved off a map (the title, a load screen) the slot would load into a game with no map and end it.
      return { "error" => "the game can only save while it is on a map" } if !$game_map || $game_map.map_id.to_i <= 0
      # Nor with a message or choice up: the game never saves then, and a choice holds a Proc no save can store.
      showing = ($game_message.respond_to?(:busy?) && $game_message.busy?) ||
                ($game_temp.respond_to?(:message_window_showing) && $game_temp.message_window_showing)
      return { "error" => "the game can only save when no message is on screen" } if showing
      if defined?(DataManager)
        # save_game swallows the reason; the version without the rescue says what went wrong, and like
        # save_game, a failed write leaves no half-written slot behind.
        index = slot_index(file)
        begin
          if DataManager.respond_to?(:save_game_without_rescue)
            DataManager.save_game_without_rescue(index)
          elsif !DataManager.save_game(index)
            return { "error" => "the game could not save #{file}" }
          end
        rescue StandardError => e
          File.delete(DataManager.make_filename(index)) rescue nil
          # Name the part of the save that would not serialise (a script's Proc in $game_system, say).
          part = (DataManager.make_save_contents.find { |_, v| (Marshal.dump(v) && false) rescue true } rescue nil)
          where = part ? " (in #{part[0]})" : ""
          return { "error" => "the game could not save #{file}: #{e.class}: #{e.message}#{where}" }
        end
      elsif defined?(Scene_Save) || defined?(Scene_File)
        begin
          File.open(file, "wb") do |f|
            defined?(Scene_Save) ? Scene_Save.new.send(:write_save_data, f) : Scene_File.new(true, false, false).send(:write_save_data, f)
          end
        rescue StandardError => e
          File.delete(file) rescue nil
          return { "error" => "the game could not save #{file}: #{e.class}: #{e.message}" }
        end
      else
        return { "error" => "this game has no save code OmniPlay knows" }
      end
      {}
    end

    def handle(json)
      request = parse(json)
      # The host stopped waiting at "expires" (seconds since 1970) and told the player so; doing it now would apply
      # an edit reported as failed.
      return dump({ "error" => "timedOut" }) if request["expires"] && Time.now.to_f > request["expires"]
      return dump({ "error" => "notInGame" }) unless ready?
      reply = case request["op"]
              when "list"
                all = entries(request["category"], request["query"])
                offset = request["offset"].to_i
                size = request["size"].to_i
                { "entries" => all[offset, size] || [], "hasMore" => offset + size < all.size }
              when "get"
                { "entries" => [{ "target" => request["target"], "name" => "", "value" => read(request["target"]), "editable" => true }], "hasMore" => false }
              when "set" then write(request["target"], request["operation"] || "set", request["value"])
              when "freeze" then freeze_target(request["target"], request["value"])
              when "unfreeze"
                frozen.delete(frozen_key(request["target"]))
                {}
              when "metadata" then { "variables" => $data_system.variables, "switches" => $data_system.switches }
              when "loadSlot" then load_slot(request["file"].to_s)
              when "saveSlot" then save_slot(request["file"].to_s)
              else { "error" => "unknown op #{request["op"]}" }
              end
      dump(reply)
    rescue Exception => e
      dump({ "error" => "#{e.class}: #{e.message}" })
    end
  end
end
