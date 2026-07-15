# Guard against emailing real people from any NON-production environment.
#
# Only addresses on the allowlist are delivered; every other recipient is dropped,
# and a message left with no recipients is not sent at all. The allowlist is
# MAIL_ALLOWLIST (comma-separated, exact-match, case-insensitive).
#
#   UNSET ⇒ deny-all — nothing leaves a non-prod box (the safe default).
#   Set it in your LOCAL env to receive your own test mail, e.g.
#     MAIL_ALLOWLIST=you@example.com
#   (Keep it in your gitignored dev env, not a committed file — this repo is public.)
#
# Registered in development (and any future staging), but NOT test: the test env
# already uses delivery_method :test (mail is captured in ActionMailer::Base
# .deliveries, never sent), and registering here would flip perform_deliveries off
# and empty that array, breaking the mailer/notification tests. Prod is untouched.
class NonProdMailGuard
  # Delivery methods that never leave the machine — nothing to guard, so let them
  # through untouched (e.g. letter_opener still shows every dev email regardless of
  # recipient). Matched by class NAME so we don't have to load LetterOpener, a
  # dev-only gem, in other environments. Anything NOT listed here is guarded (fail
  # closed): an API sender we don't recognise must not silently escape the allowlist.
  LOCAL_DELIVERY_METHODS = %w[
    Mail::TestMailer
    Mail::FileDelivery
    LetterOpener::DeliveryMethod
  ].freeze

  def self.allowlist
    ENV.fetch("MAIL_ALLOWLIST", "").split(",").filter_map { |a| a.strip.downcase.presence }
  end

  def self.delivering_email(message)
    return if LOCAL_DELIVERY_METHODS.include?(message.delivery_method.class.name)

    allowed = allowlist
    keep = ->(addresses) { Array(addresses).select { |a| allowed.include?(a.to_s.downcase) } }

    message.to  = keep.call(message.to)
    message.cc  = keep.call(message.cc)
    message.bcc = keep.call(message.bcc)

    # No allowlisted recipient survived → don't send at all.
    message.perform_deliveries = false if [ message.to, message.cc, message.bcc ].all?(&:blank?)
  end
end

unless Rails.env.production? || Rails.env.test?
  ActionMailer::Base.register_interceptor(NonProdMailGuard)
end
