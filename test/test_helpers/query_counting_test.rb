require "test_helper"

# The suite's own SQL-observation plumbing: counting what a block asks the
# database (the N+1 guards) and pinning the ORDER it asks in (the lock-before-read
# guards). Both are shared, so both are pinned here rather than in whichever test
# happened to need them first.
class QueryCountingTest < ActiveSupport::TestCase
  setup { @monitor = monitors(:up) }

  test "count_queries_matching counts only the statements matching the pattern" do
    count = count_queries_matching(/FROM "monitors"/) do
      Monitoring::Monitor.count
      Monitoring::Monitor.where(id: @monitor.id).load
      Project.count
    end

    assert_equal 2, count, "the Project query must not be counted"
  end

  # The reason this exists rather than Rails' assert_queries_count: an N+1 loop
  # issues the SAME statement every iteration, so the query cache would hide it.
  test "count_queries_matching counts a repeated identical query every time" do
    count = count_queries_matching(/FROM "monitors"/) do
      Monitoring::Monitor.uncached { 3.times { Monitoring::Monitor.where(id: @monitor.id).load } }
    end

    assert_equal 3, count
  end

  test "count_queries_matching ignores schema lookups" do
    assert_equal 0, count_queries_matching(/./) { Monitoring::Monitor.connection.schema_cache.columns("monitors") }
  end

  test "sql_executed_during returns the statements in the order they were issued" do
    statements = sql_executed_during do
      Monitoring::Monitor.count
      Project.count
    end

    monitors_at = statements.index { |sql| sql.include?('FROM "monitors"') }
    projects_at = statements.index { |sql| sql.include?('FROM "projects"') }

    assert monitors_at, "the monitors query should be recorded"
    assert projects_at, "the projects query should be recorded"
    assert monitors_at < projects_at, "the statements must keep their real order"
  end

  test "assert_sql_order passes when the first pattern is issued before the second" do
    assert_sql_order(before: /FROM "monitors"/, after: /FROM "projects"/) do
      Monitoring::Monitor.count
      Project.count
    end
  end

  test "assert_sql_order fails when the order is the wrong way round" do
    error = assert_raises(Minitest::Assertion) do
      assert_sql_order(before: /FROM "monitors"/, after: /FROM "projects"/) do
        Project.count
        Monitoring::Monitor.count
      end
    end

    assert_match(/before/, error.message)
  end

  test "assert_sql_order says which pattern never showed up at all" do
    error = assert_raises(Minitest::Assertion) do
      assert_sql_order(before: /FROM "monitors"/, after: /FROM "nothing_like_this"/) do
        Monitoring::Monitor.count
      end
    end

    assert_match(/nothing_like_this/, error.message,
      "a missing statement must name itself, not just report a nil comparison")
  end
end
