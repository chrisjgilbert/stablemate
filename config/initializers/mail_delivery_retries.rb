# Bounded retries for outgoing mail. For an uptime monitor the message IS the
# product — a down/recovered alert lost to one 4xx greylisting or a dropped
# connection is the worst failure mode we have.
#
# Why StandardError rather than an enumerated SMTP error list: the transient set is
# not cleanly enumerable, and misclassifying a transient error as permanent loses
# an alert. Retrying a genuinely permanent error a handful of times costs a few
# queue slots and some log noise; that trade is deliberately lopsided. After the
# bounded attempts the job fails for real and lands in Solid Queue's failed-jobs
# table, where an operator can see it.
ActiveSupport.on_load(:action_mailer) do
  ActionMailer::MailDeliveryJob.retry_on StandardError, wait: :polynomially_longer, attempts: 5
end
