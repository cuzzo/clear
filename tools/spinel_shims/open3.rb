# frozen_string_literal: true

# Open3 is reached only by the FFI C-header importer, which shells out to a C
# compiler. Compiling CLEAR never takes that path, so the shim exists to satisfy
# the require and fails loudly rather than silently returning nothing.
module Open3
  def self.capture3(*command)
    raise NotImplementedError,
          "Open3.capture3 is not available in the Spinel build (#{command.join(' ')})"
  end

  def self.capture2(*command)
    raise NotImplementedError,
          "Open3.capture2 is not available in the Spinel build (#{command.join(' ')})"
  end
end
