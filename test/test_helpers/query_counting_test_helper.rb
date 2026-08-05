# Counting how many times a block ASKS the database something — the assertion
# behind our N+1 guards.
#
# Not Rails' `assert_queries_count`, which skips cached queries: an N+1 loop
# issues the SAME statement every iteration, so the query cache would hide it and
# the guard would pass with or without the hoisting it protects.
module QueryCountingTestHelper
  # Every sql.active_record event in the block matching `pattern`, CACHE hits
  # included; schema lookups excluded as cross-test noise.
  def count_queries_matching(pattern)
    count = 0
    counter = lambda do |*, payload|
      count += 1 if payload[:name] != "SCHEMA" && payload[:sql].to_s.match?(pattern)
    end
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
    count
  end
end
