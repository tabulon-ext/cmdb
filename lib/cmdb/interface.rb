require 'json'

module CMDB
  class Interface
    # Create a new instance of the CMDB interface.
    # @option settings [String] root name of subkey to consider as root
    def initialize(settings={})
      @root = settings[:root] if settings

      namespaces = {}

      load_file_sources(namespaces)
      check_overlap(namespaces)

      @sources = []
      # Load from consul source first if one is available.
      if !ConsulSource.url.nil?
        if ConsulSource.prefixes.nil? || ConsulSource.prefixes.empty?
          @sources << ConsulSource.new('')
        else
          ConsulSource.prefixes.each do |prefix|
            @sources << ConsulSource.new(prefix)
          end
        end
      end
      # Register valid sources with CMDB
      namespaces.each do |_, v|
        @sources << v.first
      end
    end

    # Retrieve the value of a CMDB key, searching all sources in the order they were initialized.
    #
    # @return [Object,nil] the value of the key, or nil if key not found
    # @param [String] key
    # @raise [BadKey] if the key name is malformed
    def get(key)
      raise BadKey.new(key) unless key =~ VALID_KEY
      value = nil

      @sources.each do |s|
        value = s.get(key)
        break unless value.nil?
      end

      value
    end

    # Retrieve the value of a CMDB key; raise an exception if the key is not found.
    #
    # @return [Object,nil] the value of the key
    # @param [String] key
    # @raise [MissingKey] if the key is absent from the CMDB
    # @raise [BadKey] if the key name is malformed
    def get!(key)
      get(key) || raise(MissingKey.new(key))
    end

    # Enumerate all of the keys in the CMDB.
    #
    # @yield every key/value in the CMDB
    # @yieldparam [String] key
    # @yieldparam [Object] value
    # @return [Interface] always returns self
    def each_pair(&block)
      @sources.each do |s|
        s.each_pair(&block)
      end

      self
    end

    # Transform the entire CMDB into a flat Hash that can be merged into ENV.
    # Key names are transformed into underscore-separated, uppercase strings;
    # all runs of non-alphanumeric, non-underscore characters are tranformed
    # into a single underscore.
    #
    # The transformation rules make it possible for key names to conflict,
    # e.g. "apple.orange.pear" and "apple.orange_pear" cannot exist in
    # the same flat hash. This method checks for such conflicts and raises
    # rather than returning bad data.
    #
    # @raise [NameConflict] if two or more key names transform to the same
    def to_h
      values = {}
      sources = {}

      each_pair do |key, value|
        env_key = key_to_env(key)
        value = JSON.dump(value) unless value.is_a?(String)

        if sources.key?(env_key)
          raise NameConflict.new(env_key, [sources[env_key], key])
        else
          sources[env_key] = key
          values[env_key] = value_to_env(value)
        end
      end

      values
    end

    private

    # Scan for CMDB data files and index them by namespace
    def load_file_sources(namespaces)
      # Consult standard base directories for data files
      directories = FileSource.base_directories

      # Also consult working dir in development environments
      if CMDB.development?
        local_dir   = File.join(Dir.pwd, '.cmdb')
        directories += [local_dir]
      end

      directories.each do |dir|
        (Dir.glob(File.join(dir, '*.js')) + Dir.glob(File.join(dir, '*.json'))).each do |filename|
          source = FileSource.new(filename, @root)
          namespaces[source.prefix] ||= []
          namespaces[source.prefix] << source
        end

        (Dir.glob(File.join(dir, '*.yml')) + Dir.glob(File.join(dir, '*.yaml'))).each do |filename|
          source = FileSource.new(filename, @root)
          namespaces[source.prefix] ||= []
          namespaces[source.prefix] << source
        end
      end
    end

    # Check for overlapping namespaces and react appropriately. This can happen when a file
    # of a given name is located in more than one of the key-search directories. We tolerate
    # this in development mode, but raise an exception otherwise.
    def check_overlap(namespaces)
      overlapping = namespaces.select { |_, sources| sources.size > 1 }
      overlapping.each do |ns, sources|
        exc = ValueConflict.new(ns, sources)

        if CMDB.development?
          CMDB.log.warn exc.message
        else
          raise exc
        end
      end
    end

    # Make an environment variable out of a key name
    def key_to_env(key)
      env_name = key
      env_name.gsub!(/[^A-Za-z0-9_]+/,'_')
      env_name.upcase!
      env_name
    end

    # Make a CMDB value storable in the process environment (ENV hash)
    def value_to_env(value)
      case value
      when String
        value
      else
        JSON.dump(value)
      end
    end
  end
end
