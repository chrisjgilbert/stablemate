class User
  # Non-blocking email verification (locked decision #3): an unverified user is
  # fully usable — nothing in the app gates on verified_at.
  module Verification
    extend ActiveSupport::Concern

    def verified?
      verified_at.present?
    end

    def send_verification_email
      UserMailer.verification(self).deliver_later
    end
  end
end
