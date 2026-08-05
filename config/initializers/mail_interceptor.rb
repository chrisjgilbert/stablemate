# Guard against emailing real people from any NON-production environment.
#
#   MAIL_ALLOWLIST UNSET ⇒ deny-all — nothing leaves a non-prod box.
#   Set it in your LOCAL env to receive your own test mail, e.g.
#     MAIL_ALLOWLIST=you@example.com
#   (Keep it in your gitignored dev env, not a committed file — this repo is public.)
#
# Registered in development (and any future staging), but NOT test: registering
# here would flip perform_deliveries off and empty ActionMailer::Base.deliveries,
# breaking the mailer/notification tests.
class NonProdMailGuard
  # Delivery methods that never leave the machine — nothing to guard. Matched by
  # class NAME so we don't have to load LetterOpener, a dev-only gem, in other
  # environments. Anything NOT listed here is guarded (fail closed): an API sender
  # we don't recognise must not silently escape the allowlist.
  LOCAL_DELIVERY_METHODS = %w[
    Mail::TestMailer
    Mail::FileDelivery
    LetterOpener::DeliveryMethod
  ].freeze

  # Which environments this guards. Production sends to real people on purpose;
  # test registers nothing, because an interceptor here would flip
  # perform_deliveries off and empty ActionMailer::Base.deliveries, breaking the
  # mailer and notification tests. Everything else — development, and any future
  # staging — is a box that can reach real inboxes by accident, so it is guarded.
  #
  # A predicate rather than an inline condition below so the rule can be asked in
  # a test without booting the environment it describes.
  def self.guards?(env)
    !%w[production test].include?(env.to_s)
  end

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

# on_load rather than touching ActionMailer::Base here (matching
# mail_delivery_retries.rb): referencing the constant at initializer-load time
# would force action_mailer/base.rb to load during boot, coupling other
# initializers to our position in the load order.
if NonProdMailGuard.guards?(Rails.env)
  ActiveSupport.on_load(:action_mailer) do
    ActionMailer::Base.register_interceptor(NonProdMailGuard)
  end
end
