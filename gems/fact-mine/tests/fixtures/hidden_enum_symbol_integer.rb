class Job
  def initialize
    @phase = :queued
    @attempt = 1
  end

  def queued?
    @phase == :queued && @attempt == 1
  end

  def done?
    @phase == :done && @attempt == 2
  end
end
