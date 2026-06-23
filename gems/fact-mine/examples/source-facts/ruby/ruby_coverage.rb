# sig { params(x: String).void }
# sig { void }
TopLevelAlias = T.type_alias { String }

class RubyCoverageParent
  class RubyCoverageChild
    MyType = T.type_alias { T.any(String, Hash{Symbol => String}) }
    MyType2 = T.type_alias do
      Integer
    end
    MyType3 = T.type_alias Float

    def initialize
      @x = 1
      $global_var = 2
    end

    sig { params(val: Integer).void }
    def method_missing(symbol, *args)
      super
      super(symbol, *args)
      yield
      yield(symbol)
    end

    def respond_to_missing?(symbol, include_private = false)
      if self.some_call
        puts "yes"
      end
      self.some_call
    end

    def some_call
      if !@x == 1
        puts "not 1"
      elsif self.some_call == 1
        puts "some_call is 1"
      elsif @x == 2
        puts "2"
      else
        puts "other"
      end

      case @x
      when 1
        puts "one"
      end

      begin
        puts "trying"
      rescue StandardError => e
        nil
      end

      begin
        puts "inline"
      rescue
        nil
      end

      1 while false
      1 until true
      `ls`

      class << self
        def class_method
          nil
        end
      end
    end
  end
end
