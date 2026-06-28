class User
  # Non-blocking email verification (locked decision #3): we send a verification
  # email on signup, but an unverified user is fully usable — verified_at simply
  # stays null until they click. Nothing in the app gates on it in V1.
  module Verification
    extend ActiveSupport::Concern

    def verified?
      verified_at.present?
    end

    # Fire-and-forget verification email. Enqueued (deliver_later) so signup never
    # blocks on mail delivery.
    def send_verification_email
      UserMailer.verification(self).deliver_later
    end
  end
end
