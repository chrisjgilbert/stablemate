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

  # Ping-history retention in whole days, from the constant the models prune and
  # chart by, so marketing's "90-day history" claims can't drift from the product
  # (same idea as free_plan_monitors_phrase).
  def ping_retention_days
    (Stablemate::PING_RETENTION / 1.day).to_i
  end

  # Whether to render any billing UI. False on a keyless self-host instance, where
  # there are no plans and nothing to link to (issue #19 config-gate).
  def billing_enabled?
    Stablemate.billing_enabled?
  end

  # Whether to render the Cloudflare Web Analytics beacon. False on a keyless
  # self-host instance (same config-gate shape as billing_enabled?). Only
  # layouts/landing actually renders the beacon (see
  # app/views/layouts/_analytics.html.erb) — layouts/application must not, since
  # it also serves token-bearing URLs the beacon would report.
  def cloudflare_analytics_enabled?
    Stablemate.cloudflare_analytics_token.present?
  end

  # The GitHub repo, and a doc within it — one source for the marketing pages
  # (home, pricing, and their shared nav/colophon partials) so a docs move or a
  # repo rename can't leave one of them pointing at a stale link.
  def stablemate_repo_url
    "https://github.com/chrisjgilbert/stablemate"
  end

  def stablemate_docs_url(path)
    "#{stablemate_repo_url}/blob/main/docs/#{path}"
  end
end
