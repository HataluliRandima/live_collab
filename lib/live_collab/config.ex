defmodule LiveCollab.Config do
  @moduledoc """
  Configuration for LiveCollab.

  Values are read from the application environment and may be overridden per
  call through the options of `LiveCollab.track/4`:

      config :live_collab,
        presence: MyAppWeb.Presence,
        pubsub: MyApp.PubSub,
        topic_prefix: "live_collab",
        max_field_id_length: 255,
        telemetry_rate_per_sec: 50,
        telemetry_burst_limit: 60,
        presence_rate_per_sec: 20,
        presence_burst_limit: 40,
        presence_sync_interval_ms: 50,
        clock_skew_tolerance_ms: 500

  ## Options

    * `:presence` - your `Phoenix.Presence` module (**required**).
    * `:pubsub` - your `Phoenix.PubSub` server. Optional: when omitted it is read
      from the Presence module's `:pubsub_server` option.
    * `:topic_prefix` - prefix for collaboration topics (default `"live_collab"`).
    * `:max_field_id_length` - maximum byte size of client-supplied field, element
      and container identifiers (default `255`, at most `4096`).
    * `:telemetry_rate_per_sec` / `:telemetry_burst_limit` - token bucket for
      high-frequency ephemeral events (cursor, viewport, selection, spotlight).
      Defaults `50` / `60`.
    * `:presence_rate_per_sec` / `:presence_burst_limit` - token bucket for events
      that write to `Phoenix.Presence` (field focus, element activity). Every
      Presence write is replicated to every node and every collaborator, so this
      bucket is deliberately smaller. Defaults `20` / `40`.
    * `:presence_sync_interval_ms` - minimum time between two rebuilds of
      `@collab_users` / `@collab_locks` / `@collab_activities` in one LiveView.
      A change after a quiet period is applied immediately; during a burst (many
      joins, focus changes) further changes are folded into one rebuild at the
      end of the interval. Every rebuild is O(room size), so this bounds the CPU
      a large room costs each LiveView. `0` disables throttling (bursts are then
      only coalesced when already queued). Default `50`.
    * `:clock_skew_tolerance_ms` - lock claims whose timestamps fall in the same
      window of this size are ordered by client id instead of time. See
      `LiveCollab.Field.resolve_conflict/2` (default `500`; `0` disables windows).

  Invalid values raise `ArgumentError` when `get/1` is called (i.e. on
  `LiveCollab.track/4`), naming the offending key.
  """

  @max_identifier_length_cap 4096

  @defaults [
    pubsub: nil,
    presence: nil,
    topic_prefix: "live_collab",
    max_field_id_length: 255,
    telemetry_rate_per_sec: 50,
    telemetry_burst_limit: 60,
    presence_rate_per_sec: 20,
    presence_burst_limit: 40,
    presence_sync_interval_ms: 50,
    clock_skew_tolerance_ms: 500
  ]

  @type t :: %__MODULE__{
          pubsub: atom() | nil,
          presence: module() | nil,
          topic_prefix: String.t(),
          max_field_id_length: pos_integer(),
          telemetry_rate_per_sec: number(),
          telemetry_burst_limit: number(),
          presence_rate_per_sec: number(),
          presence_burst_limit: number(),
          presence_sync_interval_ms: non_neg_integer(),
          clock_skew_tolerance_ms: non_neg_integer()
        }

  defstruct @defaults

  @doc """
  Returns the validated configuration, merging `overrides` over the application
  environment over the defaults. Unknown keys are ignored.

  Raises `ArgumentError` if any value is invalid.
  """
  @spec get(keyword()) :: t()
  def get(overrides \\ []) do
    env = Application.get_all_env(:live_collab)

    values =
      for {key, default} <- @defaults do
        {key, Keyword.get(overrides, key, Keyword.get(env, key, default))}
      end

    Enum.each(values, fn {key, value} -> validate!(key, value) end)
    struct!(__MODULE__, values)
  end

  @doc """
  Builds the canonical collaboration topic for a resource.

  `{type, id}` becomes `"<prefix>:<type>:<id>"`; anything else becomes
  `"<prefix>:<resource>"`.
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

  @doc """
  Resolves the PubSub server: the configured `:pubsub`, otherwise the
  `:pubsub_server` the Presence module was defined with.

  Raises `ArgumentError` with setup instructions if neither is available.
  """
  @spec pubsub_server!(t()) :: atom()
  def pubsub_server!(%__MODULE__{pubsub: pubsub}) when is_atom(pubsub) and not is_nil(pubsub),
    do: pubsub

  def pubsub_server!(%__MODULE__{presence: presence}) do
    presence_pubsub(presence) ||
      raise ArgumentError, """
      LiveCollab could not determine the Phoenix.PubSub server.

      Configure it explicitly:

          config :live_collab, pubsub: MyApp.PubSub

      or pass it to LiveCollab.track(socket, resource, user, pubsub: MyApp.PubSub)
      """
  end

  # `use Phoenix.Presence` stores its options in the generated child_spec/1.
  defp presence_pubsub(presence) when is_atom(presence) and not is_nil(presence) do
    with true <- Code.ensure_loaded?(presence),
         true <- function_exported?(presence, :child_spec, 1),
         %{start: {Phoenix.Presence, :start_link, [_mod, _sup, opts]}} <-
           presence.child_spec([]),
         pubsub when is_atom(pubsub) and not is_nil(pubsub) <- opts[:pubsub_server] do
      pubsub
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp presence_pubsub(_), do: nil

  defp validate!(key, value) when key in [:pubsub, :presence] do
    unless is_nil(value) or (is_atom(value) and value not in [true, false]) do
      invalid!(key, value, "a module/atom or nil")
    end
  end

  defp validate!(:topic_prefix, value) do
    unless is_binary(value) and value != "" do
      invalid!(:topic_prefix, value, "a non-empty string")
    end
  end

  defp validate!(:max_field_id_length, value) do
    unless is_integer(value) and value > 0 and value <= @max_identifier_length_cap do
      invalid!(
        :max_field_id_length,
        value,
        "an integer between 1 and #{@max_identifier_length_cap}"
      )
    end
  end

  defp validate!(key, value) when key in [:telemetry_rate_per_sec, :presence_rate_per_sec] do
    unless is_number(value) and value > 0, do: invalid!(key, value, "a positive number")
  end

  defp validate!(key, value) when key in [:telemetry_burst_limit, :presence_burst_limit] do
    unless is_number(value) and value >= 1, do: invalid!(key, value, "a number >= 1")
  end

  defp validate!(:presence_sync_interval_ms, value) do
    unless is_integer(value) and value >= 0 and value <= 60_000 do
      invalid!(:presence_sync_interval_ms, value, "an integer between 0 and 60000")
    end
  end

  defp validate!(:clock_skew_tolerance_ms, value) do
    unless is_integer(value) and value >= 0 do
      invalid!(:clock_skew_tolerance_ms, value, "a non-negative integer")
    end
  end

  @spec invalid!(atom(), term(), String.t()) :: no_return()
  defp invalid!(key, value, expected) do
    raise ArgumentError,
          "invalid LiveCollab configuration for #{inspect(key)}: expected #{expected}, got: #{inspect(value)}"
  end
end
