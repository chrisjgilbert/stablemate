require_relative "boot"

# The `rails/all` list, minus the three frameworks this app has no use for:
# active_storage/engine, action_mailbox/engine and action_text/engine. Nothing
# here declares an attachment or rich text — no has_one_attached, no
# has_rich_text, no ApplicationMailbox, and active_storage:install was never run,
# so the schema has no active_storage_* or action_mailbox_* tables. The other two
# are listed with Active Storage because both depend on it.
#
# `rails/all` is the generated default and staying on it would be the
# conventional choice; the reason to leave is that it was booting three
# frameworks per process — web, jobs, console, every test run — and mounting
# routes that could never match, purely because the file says "all". Loading the
# frameworks you use is the same convention, written out.
#
# Add a railtie back the moment something needs it: an attachment needs
# active_storage/engine here, `config.active_storage.service` in the environment
# files, a `config/storage.yml`, and the image_processing/ruby-vips pair the
# Gemfile note describes.
require "rails"

%w[
  active_record/railtie
  action_controller/railtie
  action_view/railtie
  action_mailer/railtie
  active_job/railtie
  action_cable/engine
  rails/test_unit/railtie
].each { |railtie| require railtie }

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Stablemate
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")
  end
end
