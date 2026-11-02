defmodule LiveCollab.RateLimiter do
  @moduledoc """
  Lightweight, purely functional in-memory token bucket rate limiter for socket assigns.

  Protects LiveView processes, process mailboxes, and cluster PubSub brokers from
  high-frequency telemetry flood attacks (such as modified client JS hooks emitting
  hundreds or thousands of cursor/viewport coordinates per second).

  ## Zero-Dependency, Purely Functional

  Because the rate limiter maintains its state directly in `socket.assigns`, it requires:
  - Zero GenServer processes or worker pools
  - Zero ETS tables or disk I/O
  - Zero inter-process lock contention or message passing
  - O(1) monotonic time arithmetic (`System.monotonic_time(:millisecond)`)

  ## Algorithm

  The token bucket allows short bursts up to `:burst` (default `60`), while capping
  steady-state consumption at `:rate` events per second (default `50`).
  """

  @type t :: %__MODULE__{
          tokens: float(),
          last_time_ms: integer(),
          rate_per_sec: pos_integer(),
          burst_limit: pos_integer()
        }

  defstruct tokens: 50.0,
            last_time_ms: 0,
            rate_per_sec: 50,
            burst_limit: 60

  @doc """
  Initializes a new rate limiter state.

  ## Options

  - `:rate` - Steady-state allowed events per second (default: `50`).
  - `:burst` - Maximum token capacity / burst limit (default: `60`).
  - `:now_ms` - Initial timestamp override in milliseconds (default: `System.monotonic_time(:millisecond)`).
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    rate = Keyword.get(opts, :rate, 50)
    burst = Keyword.get(opts, :burst, max(rate, 60))
    now = Keyword.get_lazy(opts, :now_ms, fn -> System.monotonic_time(:millisecond) end)

    %__MODULE__{
      tokens: burst * 1.0,
      last_time_ms: now,
      rate_per_sec: rate,
      burst_limit: burst
    }
  end

  @doc """
  Evaluates whether an incoming event should be allowed or dropped.

  Returns `{:allow, updated_limiter}` if tokens are available,
  or `{:deny, updated_limiter}` if the rate limit is exceeded.
  """
  @spec check(t() | nil, number(), integer() | nil) :: {:allow, t()} | {:deny, t()}
  def check(limiter, cost \\ 1.0, now_ms \\ nil)

  def check(nil, cost, now_ms) do
    new() |> check(cost, now_ms)
  end

  def check(%__MODULE__{} = limiter, cost, now_ms) do
    now = now_ms || System.monotonic_time(:millisecond)
    elapsed_ms = max(0, now - limiter.last_time_ms)

    # Refill tokens proportional to elapsed monotonic milliseconds
    refill = elapsed_ms * (limiter.rate_per_sec / 1000.0)
    refilled_tokens = min(limiter.burst_limit * 1.0, limiter.tokens + refill)

    if refilled_tokens >= cost do
      {:allow, %{limiter | tokens: refilled_tokens - cost, last_time_ms: now}}
    else
      {:deny, %{limiter | tokens: refilled_tokens, last_time_ms: now}}
    end
  end
end

