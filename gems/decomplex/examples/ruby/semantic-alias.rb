# frozen_string_literal: true

def frame?; @provenance == :frame; end
def is_frame?; provenance == :frame; end
def heap?; @provenance == :heap; end

def somewhere(node)
  return 1 if node.provenance == :frame
end
