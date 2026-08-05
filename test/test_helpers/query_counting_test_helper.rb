# Watching what a block asks the database — how MANY times (the N+1 guards) and
# in what ORDER (the lock-before-read guards).
#
# Not Rails' `assert_queries_count`, which skips cached queries: an N+1 loop
# issues the SAME statement every iteration, so the query cache would hide it and
# the guard would pass with or without the hoisting it protects.
module QueryCountingTestHelper
  # Every sql.active_record event in the block matching `pattern`, CACHE hits
  # included; schema lookups excluded as cross-test noise.
  def count_queries_matching(pattern, &block)
    sql_executed_during(&block).count { |sql| sql.match?(pattern) }
  end

  # The SQL a block issues, in order — the raw material for ordering assertions.
  def sql_executed_during
    statements = []
    collect = lambda do |*, payload|
      statements << payload[:sql].to_s if payload[:name] != "SCHEMA"
    end
    ActiveSupport::Notifications.subscribed(collect, "sql.active_record") { yield }
    statements
  end

  # Assert a block issued one statement before another — the lock-before-read
  # check, where asserting merely that both happened would pass on the very
  # interleaving the lock exists to prevent. Named because a bare
  # `assert a_at < b_at` reports "Expected false to be truthy", and raises on nil
  # when a pattern never matched at all.
  def assert_sql_order(before:, after:, &block)
    statements = sql_executed_during(&block)
    before_at = statements.index { |sql| sql.match?(before) }
    after_at = statements.index { |sql| sql.match?(after) }

    assert before_at, "expected a statement matching #{before.inspect}, and none was issued"
    assert after_at, "expected a statement matching #{after.inspect}, and none was issued"
    assert before_at < after_at,
      "expected #{before.inspect} to be issued before #{after.inspect}, but it came after"
  end
end
