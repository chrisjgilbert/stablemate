# frozen_string_literal: true

module Stablemate
  module Commands
    class Install
      # Where the two keys are persisted for the DEV MACHINE: an existing `.env`,
      # under the same names the argument, the initializer skeleton and the gem's
      # own defaults use. One name everywhere, or a green install boots the host
      # into "no ping_key configured" with no hint why.
      #
      # It never CREATES a `.env`. A file the host has no dotenv gem to read is a
      # silent no-op that looks like it worked, so with no `.env` present install
      # prints the `credentials:edit` lines instead — a path that works in every
      # app, and the one the skeleton falls back to anyway.
      class EnvFile
        PATH = ".env"

        def initialize(root:, values:)
          @root = root
          @values = values
        end

        def path = PATH

        def exist? = File.exist?(absolute_path)

        # Rotating for secrets, deliberately unlike the initializer: this is the
        # lost-key recovery loop — regenerate from the setup panel, paste the new
        # line, done. Refusing to update would dead-end that loop with a
        # green-looking run still carrying dead keys.
        #
        # Every other line is preserved verbatim, including an `export` prefix on
        # a line we rewrite: this is the user's file and install is a guest in it.
        def write!
          contents = File.read(absolute_path)
          values.each { |name, value| contents = upsert(contents, name, value) }
          File.write(absolute_path, contents)
        end

        private
          attr_reader :root, :values

          def absolute_path = File.expand_path(PATH, root)

          # `gsub`, not `sub`: a duplicated assignment is LAST-wins for dotenv, so
          # rewriting only the first occurrence leaves the stale value in charge —
          # and install would then report success and exit 0 while the app boots
          # with a dead key, which is the silent-success shape this command exists
          # to remove.
          def upsert(contents, name, value)
            assignment = /^([ \t]*(?:export[ \t]+)?#{Regexp.escape(name)}[ \t]*=).*$/

            return contents.gsub(assignment) { "#{Regexp.last_match(1)}#{value}" } if contents.match?(assignment)

            "#{terminated(contents)}#{name}=#{value}\n"
          end

          # A file whose last line has no newline would otherwise silently absorb
          # the appended key into it — `FOO=barSTABLEMATE_API_KEY=…`.
          def terminated(contents)
            contents.empty? || contents.end_with?("\n") ? contents : "#{contents}\n"
          end
      end
    end
  end
end
