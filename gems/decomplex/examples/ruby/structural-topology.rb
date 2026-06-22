# frozen_string_literal: true

class Worker
  def run(items)
    prepare
    if ready()
      validate
    end
    items.each do |item|
      helper(item)
    end
  end

  private

  def prepare; end
  def ready; true; end
  def validate; end
  def helper(item); item; end

  public :validate
end
