def method_five
  class << obj
    def singleton_method
    end
  end
  class << self
    def self_singleton_method
    end
  end
end
