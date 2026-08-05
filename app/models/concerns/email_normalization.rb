module EmailNormalization
  extend ActiveSupport::Concern

  included do
    normalizes :email_address, with: ->(e) { e.to_s.strip.downcase }
  end
end
