module ApplicationHelper
  # The Free-plan monitor allowance, phrased for marketing/sign-up copy. Keeps the
  # cap-on vs cap-off ("up to N" vs "unlimited", issue #16) wording in one place so
  # the home page and the sign-up screen can't drift apart.
  def free_plan_monitors_phrase
    if Stablemate.monitor_cap_enabled?
      "up to #{Stablemate::MAX_MONITORS_PER_USER} monitors"
    else
      "unlimited monitors"
    end
  end
end
