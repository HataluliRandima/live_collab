defmodule LiveCollab.Config do
  @moduledoc """
  Configuration management and runtime defaults for LiveCollab.

  Can be configured in `config/config.exs`:

      config :live_collab,
        pubsub: MyApp.PubSub,
        presence: MyApp.Presence,
        topic_prefix: "live_collab",
        max_field_id_length: 255

  Or passed dynamically to `LiveCollab.track/3`.
  """

  @default_prefix "live_collab"
  @default_max_field_len 255
  @default_telemetry_rate 50
  @default_telemetry_burst 60
  @default_clock_skew_tolerance_ms 500

  @type t :: %__MODULE__{
          pubsub: atom() | nil,
          presence: atom() | nil,
          topic_prefix: String.t(),
          max_field_id_length: pos_integer(),
          telemetry_rate_per_sec: pos_integer(),
          telemetry_burst_limit: pos_integer(),
          clock_skew_tolerance_ms: non_neg_integer()
        }

  defstruct pubsub: nil,
            presence: nil,
            topic_prefix: @default_prefix,
            max_field_id_length: @default_max_field_len,
            telemetry_rate_per_sec: @default_telemetry_rate,
            telemetry_burst_limit: @default_telemetry_burst,
            clock_skew_tolerance_ms: @default_clock_skew_tolerance_ms

  @doc """
  Returns a resolved configuration struct merging application environment with any overrides.
  """
  @spec get(keyword()) :: t()
  def get(overrides \\ []) do
    env = Application.get_all_env(:live_collab)

    %__MODULE__{
      pubsub: Keyword.get(overrides, :pubsub, Keyword.get(env, :pubsub)),
      presence: Keyword.get(overrides, :presence, Keyword.get(env, :presence)),
      topic_prefix:
        Keyword.get(overrides, :topic_prefix, Keyword.get(env, :topic_prefix, @default_prefix)),
      max_field_id_length:
        Keyword.get(
          overrides,
          :max_field_id_length,
          Keyword.get(env, :max_field_id_length, @default_max_field_len)
        ),
      telemetry_rate_per_sec:
        Keyword.get(
          overrides,
          :telemetry_rate_per_sec,
          Keyword.get(env, :telemetry_rate_per_sec, @default_telemetry_rate)
        ),
      telemetry_burst_limit:
        Keyword.get(
          overrides,
          :telemetry_burst_limit,
          Keyword.get(env, :telemetry_burst_limit, @default_telemetry_burst)
        ),
      clock_skew_tolerance_ms:
        Keyword.get(
          overrides,
          :clock_skew_tolerance_ms,
          Keyword.get(env, :clock_skew_tolerance_ms, @default_clock_skew_tolerance_ms)
        )
    }
  end

  @doc """
  Builds the canonical collaboration topic for a given resource.
  Format: `"<prefix>:<resource_type>:<resource_id>"` or `"<prefix>:<resource_key>"`
  """
  @spec topic(t(), term()) :: String.t()
  def topic(%__MODULE__{topic_prefix: prefix}, {resource_type, resource_id}) do
    "#{prefix}:#{resource_type}:#{resource_id}"
  end

  def topic(%__MODULE__{topic_prefix: prefix}, resource_key) when is_binary(resource_key) do
    "#{prefix}:#{resource_key}"
  end

  def topic(%__MODULE__{topic_prefix: prefix}, resource_id) do
    "#{prefix}:#{to_string(resource_id)}"
  end
end
