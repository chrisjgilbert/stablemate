require_relative "boot"

require "rails/all"

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

    # Nothing here declares an attachment, so we carry no image_processing /
    # ruby-vips backend (see the note in the Gemfile). Say so, rather than
    # leaving the :vips default pointing at a backend that isn't installed:
    # Active Storage's initializer swallows the resulting LoadError but logs
    # "Generating image variants require the image_processing gem…" on EVERY
    # boot, in every environment — advice that is wrong for this app and that
    # self-hosters would read in their own production log. :disabled also
    # leaves a NullTransformer in place of a nil transformer, so the day
    # someone does add an attachment they get a clear error, not a NoMethodError.
    config.active_storage.variant_processor = :disabled

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")
  end
end
