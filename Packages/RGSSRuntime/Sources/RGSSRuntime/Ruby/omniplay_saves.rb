# OmniPlay: saves for a game whose folder is read-only.
#
# RGSS games write next to themselves: "Save01.rxdata", "Save01.rvdata2", "Saves/slot1.dat", options files. OmniPlay
# keeps the imported game folder sealed, and mkxp-z resolves those relative paths literally against it, so every
# save failed with Errno::EACCES. Here a write to a path inside the game folder lands in the game's save folder
# (System.data_directory) under the same relative path, and reads, existence checks and listings look there first,
# then in the game folder. The game sees one folder.
#
# Loaded as a config preload, after the engine's own File/Dir wrappers (windows_fs.rb), which it wraps in turn.
# Written for Ruby 1.8, 1.9 and 3.1 alike.

module OmniPlaySaves
  GAME = File.expand_path(Dir.pwd).gsub("\\", "/").sub(%r{/+\z}, "")
  SAVES = if defined?(System) && System.respond_to?(:data_directory)
            System.data_directory.to_s.gsub("\\", "/").sub(%r{/+\z}, "")
          else
            ""
          end
  WRITE_FLAGS = File::WRONLY | File::RDWR | File::CREAT | File::APPEND | File::TRUNC

  module_function

  def active?
    !SAVES.empty? && SAVES != "." && SAVES != GAME
  end

  # The game-relative part of a path that addresses the game folder, or nil for anything else (the save folder
  # itself, other absolute paths, Windows drive paths, escapes).
  def relative(path)
    return nil unless active?
    return nil unless path.is_a?(String)

    p = path.gsub("\\", "/")
    return nil if p.empty? || p =~ %r{\A[A-Za-z]:/}
    if p[0, 1] == "/"
      return nil if p == SAVES || p[0, SAVES.length + 1] == SAVES + "/"
      return nil unless p[0, GAME.length + 1] == GAME + "/"

      p = p[GAME.length + 1..-1]
    end
    p = p.sub(%r{\A(\./)+}, "")
    return nil if p.empty? || p.split("/").include?("..")

    p
  end

  def saved(rel)
    SAVES + "/" + rel
  end

  def write_mode?(args)
    mode = args[0]
    mode = (mode[:mode] || mode["mode"]) if mode.is_a?(Hash)
    return mode =~ /[wa+]/ ? true : false if mode.is_a?(String)
    return (mode & WRITE_FLAGS) != 0 if mode.is_a?(Integer)

    false
  end

  def exists_here?(path)
    File._omniplay_prev_exist(path)
  end

  def make_parent(target)
    dir = File.dirname(target)
    return if File._omniplay_prev_directory(dir)

    parts = []
    while !File._omniplay_prev_directory(dir) && dir != SAVES && dir.length > SAVES.length
      parts.unshift(dir)
      dir = File.dirname(dir)
    end
    parts.each { |d| Dir._omniplay_prev_mkdir(d) unless File._omniplay_prev_directory(d) }
  end

  # Where a write lands. A file opened for update ("r+", "a") that exists only in the game folder is copied over
  # first, so the game changes its own copy of it.
  def write_target(path, args = [])
    rel = relative(path)
    return path unless rel

    target = saved(rel)
    make_parent(target)
    mode = args[0]
    mode = (mode[:mode] || mode["mode"]) if mode.is_a?(Hash)
    keeps = mode.is_a?(String) ? (mode !~ /w/) : (mode.is_a?(Integer) && (mode & File::TRUNC) == 0)
    if keeps && !exists_here?(target) && exists_here?(path)
      File._omniplay_prev_open(path, "rb") { |from| File._omniplay_prev_open(target, "wb") { |to| to.write(from.read) } }
    end
    target
  end

  # Where a read comes from: the save folder when the file is there, else the game folder.
  def read_target(path)
    rel = relative(path)
    return path unless rel

    target = saved(rel)
    exists_here?(target) ? target : path
  end
end

if OmniPlaySaves.active?
  class << File
    alias _omniplay_prev_open open unless method_defined?(:_omniplay_prev_open)
    alias _omniplay_prev_new new unless method_defined?(:_omniplay_prev_new)
    alias _omniplay_prev_exist exist? unless method_defined?(:_omniplay_prev_exist)
    alias _omniplay_prev_file file? unless method_defined?(:_omniplay_prev_file)
    alias _omniplay_prev_directory directory? unless method_defined?(:_omniplay_prev_directory)
    alias _omniplay_prev_size size unless method_defined?(:_omniplay_prev_size)
    alias _omniplay_prev_mtime mtime unless method_defined?(:_omniplay_prev_mtime)
    alias _omniplay_prev_delete delete unless method_defined?(:_omniplay_prev_delete)
    alias _omniplay_prev_rename rename unless method_defined?(:_omniplay_prev_rename)
    alias _omniplay_prev_read read unless method_defined?(:_omniplay_prev_read)
    alias _omniplay_prev_readlines readlines unless method_defined?(:_omniplay_prev_readlines)

    def open(path, *args, &block)
      target = OmniPlaySaves.write_mode?(args) ? OmniPlaySaves.write_target(path, args) : OmniPlaySaves.read_target(path)
      _omniplay_prev_open(target, *args, &block)
    end

    def new(path, *args)
      target = OmniPlaySaves.write_mode?(args) ? OmniPlaySaves.write_target(path, args) : OmniPlaySaves.read_target(path)
      _omniplay_prev_new(target, *args)
    end

    def exist?(path)
      _omniplay_prev_exist(OmniPlaySaves.read_target(path))
    end

    def exists?(path)
      _omniplay_prev_exist(OmniPlaySaves.read_target(path))
    end

    def file?(path)
      _omniplay_prev_file(OmniPlaySaves.read_target(path))
    end

    def directory?(path)
      rel = OmniPlaySaves.relative(path)
      return true if rel && _omniplay_prev_directory(OmniPlaySaves.saved(rel))

      _omniplay_prev_directory(path)
    end

    def size(path)
      _omniplay_prev_size(OmniPlaySaves.read_target(path))
    end

    def mtime(path)
      _omniplay_prev_mtime(OmniPlaySaves.read_target(path))
    end

    def read(path, *args)
      _omniplay_prev_read(OmniPlaySaves.read_target(path), *args)
    end

    def readlines(path, *args)
      _omniplay_prev_readlines(OmniPlaySaves.read_target(path), *args)
    end

    # Only the game's own copies can go; the originals in the sealed folder stay, as they would on a read-only disk.
    def delete(*paths)
      paths.each { |p| _omniplay_prev_delete(OmniPlaySaves.read_target(p)) }
      paths.length
    end

    def unlink(*paths)
      delete(*paths)
    end

    def rename(from, to)
      _omniplay_prev_rename(OmniPlaySaves.read_target(from), OmniPlaySaves.write_target(to))
    end

    if respond_to?(:ruby2_keywords, true)
      ruby2_keywords :open
      ruby2_keywords :new
      ruby2_keywords :read
      ruby2_keywords :readlines
    end
  end

  module FileTest
    class << self
      alias _omniplay_prev_exist exist? unless method_defined?(:_omniplay_prev_exist)

      def exist?(path)
        _omniplay_prev_exist(OmniPlaySaves.read_target(path))
      end

      def exists?(path)
        _omniplay_prev_exist(OmniPlaySaves.read_target(path))
      end
    end
  end

  class << Dir
    alias _omniplay_prev_glob glob unless method_defined?(:_omniplay_prev_glob)
    alias _omniplay_prev_mkdir mkdir unless method_defined?(:_omniplay_prev_mkdir)

    # Listings merge the save folder into the game folder, under the names the game would use.
    def glob(pattern, *args, &block)
      found = _omniplay_prev_glob(pattern, *args)
      prefix = OmniPlaySaves::SAVES + "/"
      (pattern.is_a?(Array) ? pattern : [pattern]).each do |p|
        rel = OmniPlaySaves.relative(p.to_s)
        next unless rel

        absolute = p.to_s.gsub("\\", "/")[0, 1] == "/"
        _omniplay_prev_glob(prefix + rel, *args).each do |hit|
          name = hit[prefix.length..-1]
          found << (absolute ? OmniPlaySaves::GAME + "/" + name : name)
        end
      end
      found = found.uniq
      return found unless block

      found.each(&block)
      nil
    end

    def [](*patterns)
      patterns.flatten.map { |p| glob(p) }.flatten.uniq
    end

    def mkdir(path, *args)
      rel = OmniPlaySaves.relative(path)
      return _omniplay_prev_mkdir(path, *args) unless rel

      target = OmniPlaySaves.saved(rel)
      OmniPlaySaves.make_parent(target)
      _omniplay_prev_mkdir(target, *args)
    end

    def exist?(path)
      File.directory?(path)
    end
  end

  module Kernel
    alias _omniplay_prev_save_data save_data unless method_defined?(:_omniplay_prev_save_data)
    alias _omniplay_prev_load_data load_data unless method_defined?(:_omniplay_prev_load_data)

    # save_data writes from C, past File.open, so it is routed here as well.
    def save_data(obj, path, *args)
      _omniplay_prev_save_data(obj, OmniPlaySaves.write_target(path), *args)
    end

    # load_data reads the game's packaged data through the engine; a file the game saved itself comes from the save
    # folder.
    def load_data(path, *args)
      rel = OmniPlaySaves.relative(path)
      if rel && OmniPlaySaves.exists_here?(OmniPlaySaves.saved(rel))
        data = File._omniplay_prev_open(OmniPlaySaves.saved(rel), "rb") { |f| f.read }
        return data if args[0]

        return Marshal.load(data)
      end
      _omniplay_prev_load_data(path, *args)
    end
    module_function :save_data, :load_data
  end
end
