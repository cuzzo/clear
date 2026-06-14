# typed: false
# frozen_string_literal: true

module AutoType
  class CLI
    def initialize(argv)
      @argv = argv.dup
    end

    def run
      NilKill.ensure_src_restored!
      command = @argv.shift
      case command
      when "apply" then Apply.new(@argv).run
      when "review" then InteractiveReview.new(@argv).run
      when "loop" then Loop.new(@argv).run
      when "guarded-autocorrect" then GuardedAutocorrect.new(@argv).run
      when "help", nil then help
      else
        warn "unknown command: #{command}"
        help
        exit 2
      end
    end

    def help
      puts <<~TEXT
        Usage:
          bundle exec auto-type apply [--dry-run]
          bundle exec auto-type review [--kind replace_nil_with_default]
          bundle exec auto-type loop [--defaults] [--try-levenshtein] [--hash-records] [--signature-backflow] [--return-backflow] [--narrow-generic] [--narrow-tlet] -- <verify command...>
          bundle exec auto-type guarded-autocorrect [--max-iterations N]

        Auto-type consumes Nil-kill evidence/actions and applies verified source rewrites.
        Ruby is the only provider implemented today; the provider interface is designed
        so other language rewriters can be added without changing Nil-kill's analyzer.

        Config:
          NIL_KILL_UNSAFE_APPLY_ALL=1         debug-only: allow raw apply --all without verification
          NIL_KILL_LEVENSHTEIN_DISTANCE=2    max param-name/class-name distance for speculative narrowing
          NIL_KILL_LEVENSHTEIN_LIMIT=50      max speculative actions per loop iteration; 0 = unlimited
          NIL_KILL_HASH_RECORD_LIMIT=1        max review hash-record promotions per loop iteration; 0 = unlimited
          NIL_KILL_SIGNATURE_BACKFLOW_LIMIT=5 max review static param backflow fixes per loop iteration; 0 = unlimited
          NIL_KILL_RETURN_BACKFLOW_LIMIT=5    max review return-backflow fixes per loop iteration; 0 = unlimited
          NIL_KILL_NARROW_GENERIC_LIMIT=0     max review narrow-generic fixes per loop iteration; 0 = unlimited
          NIL_KILL_NARROW_TLET_LIMIT=0        max review narrow-tlet fixes per loop iteration; 0 = unlimited
      TEXT
    end
  end
end
