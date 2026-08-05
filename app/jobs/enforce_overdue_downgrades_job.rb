# Daily backstop for the involuntary-downgrade grace period. Nothing is suspended
# while a user is deciding; once their grace window expires unanswered, this
# settles the account against the Free cap.
class EnforceOverdueDowngradesJob < ApplicationJob
  queue_as :default

  def perform
    each_record(User.downgrade_grace_expired, &:enforce_downgrade_fallback!)
  end
end
