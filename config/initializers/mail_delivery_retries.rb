# Bounded retries for outgoing mail (launch finding F1).
#
# Production raises SMTP errors (config/environments/production.rb), so a failed
# send fails the delivery job instead of silently discarding the message. For an
# uptime monitor the message IS the product — a down/recovered alert lost to one
# 4xx greylisting or a dropped connection is the worst failure mode we have — so
# the delivery job retries with backoff before giving up.
#
# Why StandardError rather than an enumerated SMTP error list: the transient set
# is not cleanly enumerable (Net::SMTP*, Errno::*, SocketError, OpenSSL, IOError,
# Timeout, plus whatever the relay's client raises), and misclassifying a
# transient error as permanent loses an alert. Retrying a genuinely permanent
# error a handful of times costs a few queue slots and some log noise; that trade
# is deliberately lopsided. Retries are bounded at 5 attempts (~a few minutes of
# polynomial backoff): after that the job fails for real and lands in Solid
# Queue's failed-jobs table, where an operator can see it — the one thing the old
# raise_delivery_errors = false could never do.
ActiveSupport.on_load(:action_mailer) do
  ActionMailer::MailDeliveryJob.retry_on StandardError, wait: :polynomially_longer, attempts: 5
end
