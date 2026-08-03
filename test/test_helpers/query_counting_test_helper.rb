# Counting how many times a block ASKS the database something — the assertion
# behind our N+1 guards (the dashboard's upgrade question, the uptime panel's
# live-today scan).
#
# Deliberately NOT Rails' own `capture_sql`/`assert_queries_count`: those skip
# `values[:cached]`, so a repeated identical query served from the per-request
# query cache doesn't appear at all. That is the right measure for round trips and
# exactly the wrong one for an N+1 guard — the loop we're guarding against issues
# the SAME statement every iteration, so the cache would hide it and the test would
# pass whether or not the hoisting it exists to protect is still there. We count
# the asking; the cache is a nice-to-have underneath it, not the fix.
module QueryCountingTestHelper
  # Every sql.active_record event in the block whose statement matches `pattern`,
  # CACHE hits included; schema lookups excluded, as they are noise from whichever
  # test happened to touch a table first.
  def count_queries_matching(pattern)
    count = 0
    counter = lambda do |*, payload|
      count += 1 if payload[:name] != "SCHEMA" && payload[:sql].to_s.match?(pattern)
    end
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
    count
  end
end
