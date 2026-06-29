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

  # Whether to render any billing UI. False on a keyless self-host instance, where
  # there are no plans and nothing to link to (issue #19 config-gate).
  def billing_enabled?
    Stablemate.billing_enabled?
  end
end
