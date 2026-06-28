# frozen_string_literal: true

require_relative "test_helper"

# Guards against the packaging slip where globbing only lib/**/*.rb dropped the
# rake task from the built gem, breaking `rake` in a real install.
class GemspecTest < Minitest::Test
  def gemspec
    @gemspec ||= Gem::Specification.load(File.expand_path("../stablemate.gemspec", __dir__))
  end

  def test_packages_the_rake_task
    assert_includes gemspec.files, "lib/stablemate/tasks/stablemate.rake"
  end

  def test_packages_every_lib_source_file
    %w[
      lib/stablemate.rb
      lib/stablemate/railtie.rb
      lib/stablemate/registrars/solid_queue_recurring.rb
      lib/stablemate/execution/subscriber.rb
    ].each { |f| assert_includes gemspec.files, f }
  end
end
