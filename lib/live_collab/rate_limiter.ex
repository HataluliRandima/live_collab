defmodule LiveCollab.RateLimiter do
  @moduledoc """
  Purely functional token-bucket rate limiter.

  LiveCollab keeps one bucket per LiveView process (in `socket.private`, so the
  bucket never marks assigns as changed) to drop client event floods before they
  are rebroadcast over `Phoenix.PubSub` or written to `Phoenix.Presence`.

  The bucket holds at most `:burst` tokens and refills continuously at `:rate`
  tokens per second. Each allowed event consumes `cost` tokens (default `1`).

  ## Properties

    * Pure data — no processes, no ETS. A limiter belongs to the single process
      that owns the socket, so there is no concurrent access to coordinate.
    * O(1) per check, driven by `System.monotonic_time/1` (immune to wall-clock
      jumps).
    * Time never runs backwards: if a caller supplies a `now_ms` earlier than the
      last observed time, no tokens are refilled and the reference time is kept,
      so the same interval can never be credited twice.
    * Invalid configuration (non-positive rate or burst, negative cost) raises
      `ArgumentError` instead of silently producing a limiter that always allows
      or always denies.

  ## Example

      iex> limiter = LiveCollab.RateLimiter.new(rate: 10, burst: 2, now_ms: 0)
      iex> {:allow, limiter} = LiveCollab.RateLimiter.check(limiter, 1, 0)
      iex> {:allow, limiter} = LiveCollab.RateLimiter.check(limiter, 1, 0)
      iex> {:deny, limiter} = LiveCollab.RateLimiter.check(limiter, 1, 0)
      iex> {:allow, _limiter} = LiveCollab.RateLimiter.check(limiter, 1, 100)
  """

  @type t :: %__MODULE__{
          tokens: float(),
          last_time_ms: integer(),
          rate_per_sec: number(),
          burst_limit: number()
        }

  defstruct tokens: 60.0,
            last_time_ms: 0,
            rate_per_sec: 50,
            burst_limit: 60

  @doc """
  Initializes a new rate limiter with a full bucket.

  ## Options

    * `:rate` - steady-state events per second; a positive number (default: `50`).
    * `:burst` - bucket capacity; a number `>= 1` (default: `max(rate, 60)`).
    * `:now_ms` - initial timestamp in milliseconds
      (default: `System.monotonic_time(:millisecond)`).

  Raises `ArgumentError` for invalid options.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    rate = Keyword.get(opts, :rate, 50)
    validate_rate!(rate)
    burst = Keyword.get(opts, :burst, max(rate, 60))
    validate_burst!(burst)
    now = Keyword.get_lazy(opts, :now_ms, fn -> System.monotonic_time(:millisecond) end)

    unless is_integer(now) do
      raise ArgumentError, "expected :now_ms to be an integer, got: #{inspect(now)}"
    end

    %__MODULE__{
      tokens: burst * 1.0,
      last_time_ms: now,
      rate_per_sec: rate,
      burst_limit: burst
    }
  end

  @doc """
  Decides whether an event costing `cost` tokens is allowed.

  Returns `{:allow, limiter}` (tokens consumed) or `{:deny, limiter}` (no tokens
  consumed, refill still accounted). Passing `nil` as the limiter starts from a
  default, full bucket.

  `cost` must be a non-negative number; a negative cost would mint tokens and is
  rejected with `ArgumentError`. A cost larger than the bucket capacity can never
  be satisfied and is always denied.
  """
  @spec check(t() | nil, number(), integer() | nil) :: {:allow, t()} | {:deny, t()}
  def check(limiter, cost \\ 1, now_ms \\ nil)

  def check(nil, cost, now_ms), do: check(new(now_ms: now_ms || now()), cost, now_ms)

  def check(%__MODULE__{} = limiter, cost, now_ms) do
    unless is_number(cost) and cost >= 0 do
      raise ArgumentError, "expected cost to be a non-negative number, got: #{inspect(cost)}"
    end

    now = now_ms || now()
    elapsed_ms = max(0, now - limiter.last_time_ms)
    refill = elapsed_ms * (limiter.rate_per_sec / 1000.0)
    tokens = min(limiter.burst_limit * 1.0, limiter.tokens + refill)
    limiter = %{limiter | last_time_ms: max(now, limiter.last_time_ms)}

    if tokens >= cost do
      {:allow, %{limiter | tokens: tokens - cost}}
    else
      {:deny, %{limiter | tokens: tokens}}
    end
  end

  @doc false
  @spec validate_rate!(term()) :: :ok
  def validate_rate!(rate) when is_number(rate) and rate > 0, do: :ok

  def validate_rate!(rate) do
    raise ArgumentError, "expected rate to be a positive number, got: #{inspect(rate)}"
  end

  @doc false
  @spec validate_burst!(term()) :: :ok
  def validate_burst!(burst) when is_number(burst) and burst >= 1, do: :ok

  def validate_burst!(burst) do
    raise ArgumentError, "expected burst to be a number >= 1, got: #{inspect(burst)}"
  end

  defp now, do: System.monotonic_time(:millisecond)
end
