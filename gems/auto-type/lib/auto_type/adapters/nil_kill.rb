# typed: false
# frozen_string_literal: true

module AutoType
  class NilKillAdapter
    def root
      NilKill::ROOT
    end

    def tmp_dir
      NilKill::TMP_DIR
    end

    def evidence
      NilKill::Store.read
    end

    def target_files
      NilKill.target_files
    end

    def rel(path)
      NilKill.rel(path)
    end

    def high_confidence
      NilKill::HIGH
    end

    def review_confidence
      NilKill::REVIEW
    end

    def ensure_src_restored!
      NilKill.ensure_src_restored!
    end

    def syntax
      NilKill::Syntax
    end
  end
end
