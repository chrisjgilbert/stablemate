# Daily backstop for the involuntary-downgrade grace period (projects.md §7,
# §12-J). Nothing is suspended while a user is deciding; once their grace window
# expires unanswered, this settles the account against the Free cap. Orchestration
# only: it iterates the overdue-grace scope and delegates the real work to the
# record (User#enforce_downgrade_fallback!). No domain logic here.
class EnforceOverdueDowngradesJob < ApplicationJob
  queue_as :default

  def perform
    User.downgrade_grace_expired.find_each(&:enforce_downgrade_fallback!)
  end
end
