# frozen_string_literal: true

class SourceFactLocalMethodsContracts
  def process(user, items)
    profile = user.profile
    names = []
    items.each do |item|
      if item.ready?
        names << item.name
      end
    end
    profile.name if names.any?
  end
end
