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

  # The line the user pastes into their app (v1-scope §6.6). One name for these
  # variables everywhere — the install command reads them, the initializer
  # skeleton reads them, and the .env it writes uses them — or a green install
  # boots the host into "no ping_key configured" with no hint why.
  def setup_command(pair)
    "bin/rails stablemate:install " \
      "STABLEMATE_API_KEY=#{pair.api_key_token} STABLEMATE_PING_KEY=#{pair.ping_key_token}"
  end

  # The same line after a reload. Only digests are stored, so the keys are shown
  # by their last four characters — enough to tell which pair is configured
  # somewhere, which is the only question a masked command can answer.
  def masked_setup_command(api_keys, ping_keys)
    "bin/rails stablemate:install " \
      "STABLEMATE_API_KEY=#{api_keys.first&.masked || "sm_live_…"} " \
      "STABLEMATE_PING_KEY=#{ping_keys.first&.masked || "sm_ping_…"}"
  end
end
