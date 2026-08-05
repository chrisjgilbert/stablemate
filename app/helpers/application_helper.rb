module ApplicationHelper
  # Keeps the cap-on vs cap-off wording in one place so the home page and the
  # sign-up screen can't drift apart.
  def free_plan_monitors_phrase
    if Stablemate.monitor_cap_enabled?
      "up to #{Stablemate::MAX_MONITORS_PER_USER} monitors"
    else
      "unlimited monitors"
    end
  end

  # Read off the constant the models prune and chart by, so marketing's "90-day
  # history" claims can't drift from the product.
  def ping_retention_days
    (Stablemate::PING_RETENTION / 1.day).to_i
  end

  def billing_enabled?
    Stablemate.billing_enabled?
  end

  def cloudflare_analytics_enabled?
    Stablemate.cloudflare_analytics_token.present?
  end

  # One source for the marketing pages so a docs move or a repo rename can't leave
  # one of them pointing at a stale link.
  def stablemate_repo_url
    "https://github.com/chrisjgilbert/stablemate"
  end

  def stablemate_docs_url(path)
    "#{stablemate_repo_url}/blob/main/docs/#{path}"
  end
end
