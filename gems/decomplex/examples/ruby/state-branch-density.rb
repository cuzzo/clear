# frozen_string_literal: true

class StateBranchChecker
  def check(admin, name)
    if admin
      @checked = true
    end

    if @checked && name == "admin"
      puts "hello"
    end
  end
end
