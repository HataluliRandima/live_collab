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

  describe "invalid configuration fails loudly" do
    test "zero, negative and non-numeric rates are rejected" do
      for rate <- [0, -1, -0.5, "50", nil, :fast] do
        assert_raise ArgumentError, ~r/rate/, fn -> RateLimiter.new(rate: rate) end
      end
    end

    test "burst limits below 1 or non-numeric are rejected" do
      for burst <- [0, 0.5, -10, "60", nil] do
        assert_raise ArgumentError, ~r/burst/, fn -> RateLimiter.new(rate: 10, burst: burst) end
      end
    end

    test "non-integer now_ms is rejected" do
      assert_raise ArgumentError, ~r/now_ms/, fn -> RateLimiter.new(now_ms: 1.5) end
    end

    test "negative and non-numeric costs are rejected instead of minting tokens" do
      limiter = RateLimiter.new(rate: 1, burst: 1, now_ms: 0)

      for cost <- [-1, -100.0, "1", nil] do
        assert_raise ArgumentError, ~r/cost/, fn -> RateLimiter.check(limiter, cost, 0) end
      end
    end

    test "fractional rates are supported" do
      limiter = RateLimiter.new(rate: 0.5, burst: 1, now_ms: 0)
      {:allow, limiter} = RateLimiter.check(limiter, 1, 0)
      {:deny, limiter} = RateLimiter.check(limiter, 1, 1_999)
      assert {:allow, _} = RateLimiter.check(limiter, 1, 2_000)
    end
  end

  describe "boundary conditions" do
    test "zero-cost events are always allowed and consume nothing" do
      limiter = RateLimiter.new(rate: 1, burst: 1, now_ms: 0)
      {:allow, limiter} = RateLimiter.check(limiter, 1, 0)
      assert {:allow, %{tokens: +0.0}} = RateLimiter.check(limiter, 0, 0)
    end

    test "a cost larger than the bucket is always denied" do
      limiter = RateLimiter.new(rate: 1_000, burst: 5, now_ms: 0)
      assert {:deny, _} = RateLimiter.check(limiter, 6, 1_000_000)
    end

    test "an event costing exactly the remaining tokens is allowed" do
      limiter = RateLimiter.new(rate: 1, burst: 3, now_ms: 0)
      assert {:allow, %{tokens: +0.0}} = RateLimiter.check(limiter, 3, 0)
    end

    test "tokens never exceed the burst capacity, even after very long idle periods" do
      limiter = RateLimiter.new(rate: 1_000, burst: 10, now_ms: 0)
      {:allow, limiter} = RateLimiter.check(limiter, 1, 0)
      {:allow, limiter} = RateLimiter.check(limiter, 1, 9_000_000_000_000)
      assert limiter.tokens == 9.0
    end

    test "a deny does not consume tokens but does account for refill" do
      limiter = RateLimiter.new(rate: 10, burst: 1, now_ms: 0)
      {:allow, limiter} = RateLimiter.check(limiter, 1, 0)
      {:deny, limiter} = RateLimiter.check(limiter, 1, 50)
      assert_in_delta limiter.tokens, 0.5, 1.0e-9
      assert {:allow, _} = RateLimiter.check(limiter, 1, 100)
    end
  end

  describe "time handling" do
    test "a timestamp earlier than the last one refills nothing" do
      limiter = RateLimiter.new(rate: 10, burst: 1, now_ms: 1_000)
      {:allow, limiter} = RateLimiter.check(limiter, 1, 1_000)
      assert {:deny, _} = RateLimiter.check(limiter, 1, 0)
    end

    test "regression: going back in time never credits the same interval twice" do
      # Previously last_time_ms was set to the (earlier) supplied time, so the
      # next call re-credited the interval between the two timestamps.
      limiter = RateLimiter.new(rate: 10, burst: 1, now_ms: 1_000)
      {:allow, limiter} = RateLimiter.check(limiter, 1, 1_000)
      {:deny, limiter} = RateLimiter.check(limiter, 1, 500)
      assert limiter.last_time_ms == 1_000
      assert {:deny, _} = RateLimiter.check(limiter, 1, 1_050)
      assert {:allow, _} = RateLimiter.check(limiter, 1, 1_100)
    end

    test "uses the monotonic clock when no time is supplied" do
      limiter = RateLimiter.new(rate: 1, burst: 1)
      assert {:allow, limiter} = RateLimiter.check(limiter)
      assert {:deny, _} = RateLimiter.check(limiter)
    end

    test "steady state converges to the configured rate" do
      limiter = RateLimiter.new(rate: 50, burst: 60, now_ms: 0)

      # A client sending 1000 events/s for 10 simulated seconds.
      {allowed, _} =
        Enum.reduce(0..9_999, {0, limiter}, fn t, {n, l} ->
          case RateLimiter.check(l, 1, t) do
            {:allow, l} -> {n + 1, l}
            {:deny, l} -> {n, l}
          end
        end)

      # burst (60) + 10s * 50/s, within floating point rounding
      assert allowed in 558..560
    end
  end

  property_like_seeds = [1, 2, 3, 42, 1234]

  for seed <- property_like_seeds do
    test "invariant: 0 <= tokens <= burst for random event streams (seed #{seed})" do
      :rand.seed(:exsss, {unquote(seed), 0, 0})
      limiter = RateLimiter.new(rate: 37, burst: 11, now_ms: 0)

      Enum.reduce(1..5_000, {limiter, 0}, fn _, {l, t} ->
        t = t + :rand.uniform(40) - 5
        cost = :rand.uniform(3) - 1
        {_decision, l} = RateLimiter.check(l, cost, t)
        assert l.tokens >= 0.0 and l.tokens <= 11.0
        {l, t}
      end)
    end
  end
end
