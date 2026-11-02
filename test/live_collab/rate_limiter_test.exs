defmodule LiveCollab.RateLimiterTest do
  use ExUnit.Case, async: true
  alias LiveCollab.RateLimiter

  describe "new/1" do
    test "initializes with default options" do
      limiter = RateLimiter.new()
      assert limiter.rate_per_sec == 50
      assert limiter.burst_limit == 60
      assert limiter.tokens == 60.0
      assert is_integer(limiter.last_time_ms)
    end

    test "accepts custom rate and burst options" do
      limiter = RateLimiter.new(rate: 20, burst: 30, now_ms: 1000)
      assert limiter.rate_per_sec == 20
      assert limiter.burst_limit == 30
      assert limiter.tokens == 30.0
      assert limiter.last_time_ms == 1000
    end
  end

  describe "check/3 token bucket consumption and refill" do
    test "allows burst up to burst_limit" do
      limiter = RateLimiter.new(rate: 10, burst: 5, now_ms: 1000)

      # Consume all 5 burst tokens at the exact same millisecond
      {:allow, l1} = RateLimiter.check(limiter, 1, 1000)
      assert_in_delta l1.tokens, 4.0, 0.001

      {:allow, l2} = RateLimiter.check(l1, 1, 1000)
      assert_in_delta l2.tokens, 3.0, 0.001

      {:allow, l3} = RateLimiter.check(l2, 1, 1000)
      assert_in_delta l3.tokens, 2.0, 0.001

      {:allow, l4} = RateLimiter.check(l3, 1, 1000)
      assert_in_delta l4.tokens, 1.0, 0.001

      {:allow, l5} = RateLimiter.check(l4, 1, 1000)
      assert_in_delta l5.tokens, 0.0, 0.001

      # 6th immediate request must be denied
      {:deny, l6} = RateLimiter.check(l5, 1, 1000)
      assert_in_delta l6.tokens, 0.0, 0.001
    end

    test "refills tokens over elapsed time" do
      # 50 tokens per sec = 1 token every 20ms
      limiter = RateLimiter.new(rate: 50, burst: 10, now_ms: 1000)

      # Drain the bucket completely
      {:allow, drained} = RateLimiter.check(limiter, 10, 1000)
      assert_in_delta drained.tokens, 0.0, 0.001

      # Immediate request is denied
      assert {:deny, _} = RateLimiter.check(drained, 1, 1000)

      # After 100ms (5 tokens refilled)
      {:allow, refilled} = RateLimiter.check(drained, 1, 1100)
      # 5 tokens refilled, 1 consumed = 4 remaining
      assert_in_delta refilled.tokens, 4.0, 0.001

      # After 10 seconds of idle, tokens cap at burst_limit
      {:allow, capped} = RateLimiter.check(refilled, 1, 11_100)
      # 10 burst limit, 1 consumed = 9 remaining
      assert_in_delta capped.tokens, 9.0, 0.001
    end

    test "handles nil limiter gracefully by creating default state" do
      assert {:allow, updated} = RateLimiter.check(nil, 1)
      assert %RateLimiter{} = updated
    end
  end
end
