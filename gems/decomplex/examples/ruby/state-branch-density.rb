# frozen_string_literal: true

class StateBranchUser < T::Struct
  const :name, String
  const :admin, T::Boolean
end

class StateBranchChecker
  sig { params(user: StateBranchUser).void }
  def check(user)
    if user.admin
      @checked = true
    end

    if @checked && user.name == "admin"
      puts "hello"
    end
  end
end
