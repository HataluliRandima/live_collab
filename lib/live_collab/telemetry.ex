defmodule LiveCollab.Telemetry do
  @moduledoc """
  `:telemetry` events emitted by LiveCollab.

  Collaboration happens inside many independent LiveView processes, so problems
  such as clients flooding events, invalid payloads, lock contention or
  expensive presence recomputation in large rooms are invisible by default.
  LiveCollab emits the events below so they can be logged, graphed in
  `Phoenix.LiveDashboard`, or exported to any metrics backend.

  All events share this metadata:

    * `:topic` - the collaboration topic
    * `:client_id` - the server-generated id of the LiveView that emitted it
    * `:user_key` - the Presence key (stringified user id)

  Client-supplied payloads are **never** included in metadata, so attaching a
  logger cannot be abused to inject content into your logs.

  ## Session

    * `[:live_collab, :session, :start]` - a connected LiveView started tracking.
      Measurements: `%{system_time: integer}`.
    * `[:live_collab, :session, :stop]` - `LiveCollab.untrack/2` was called.
      Measurements: `%{system_time: integer}`. (A LiveView that simply exits is
      cleaned up by Presence and does not emit this event.)

  ## Presence

    * `[:live_collab, :presence, :sync]` - collaboration assigns were rebuilt
      from Presence. Measurements:
      * `:duration` - native time units spent rebuilding
      * `:users` - distinct collaborators in the room
      * `:metas` - connected clients (tabs) in the room
      * `:coalesced_diffs` - `presence_diff` messages folded into this rebuild

  ## Locks

  Extra metadata: `:field`.

    * `[:live_collab, :lock, :claimed]` - this client claimed a field.
    * `[:live_collab, :lock, :released]` - this client released its field.
    * `[:live_collab, :lock, :denied]` - focus on a field another client holds;
      extra metadata `:holder_client_id`.
    * `[:live_collab, :lock, :lost]` - a concurrent claim won the tie-break;
      extra metadata `:winner_client_id`.

  ## Client events

    * `[:live_collab, :event, :rate_limited]` - an event was dropped by a token
      bucket. Measurements: `%{count: 1}`. Extra metadata: `:event` (string),
      `:bucket` (`:telemetry` or `:presence`) and `:consecutive` (how many events
      in a row this client has had dropped from that bucket).
    * `[:live_collab, :event, :rejected]` - an event failed validation.
      Measurements: `%{count: 1}`. Extra metadata: `:event` (string) and
      `:reason` (atom, e.g. `:disallowed_characters`, `:invalid_params`,
      `:unknown_event`).

  ## Spotlight

    * `[:live_collab, :spotlight, :started]`
    * `[:live_collab, :spotlight, :stopped]`
    * `[:live_collab, :spotlight, :unauthorized]` - extra metadata `:action`
      (`:lead` or `:stop`).

  ## Lock handoff

  Extra metadata: `:field`.

    * `[:live_collab, :lock, :requested]` - this client asked the holder for a
      field; extra metadata `:holder_client_id`.
    * `[:live_collab, :lock, :handed_off]` / `[:live_collab, :lock, :handoff_declined]` -
      the holder answered a request; extra metadata `:requester_client_id`.

  ## Conflict-aware forms

    * `[:live_collab, :field, :changes_broadcast]` - `broadcast_changes/3` was
      called. Measurements: `%{count: fields}`. Extra metadata: `:fields`.
    * `[:live_collab, :field, :conflict]` - a change arrived for a field this
      client is editing; extra metadata `:field`, `:by_client_id`.

  ## Status

    * `[:live_collab, :status, :changed]` - a tab became `:active` or `:away`;
      extra metadata `:status`.

  ## Metrics example

  With `telemetry_metrics` (included in generated Phoenix apps), add to your
  `MyAppWeb.Telemetry.metrics/0`:

      counter("live_collab.event.rate_limited.count", tags: [:event, :bucket]),
      counter("live_collab.event.rejected.count", tags: [:event, :reason]),
      counter("live_collab.lock.lost.count"),
      counter("live_collab.spotlight.unauthorized.count", tags: [:action]),
      summary("live_collab.presence.sync.duration", unit: {:native, :millisecond}),
      summary("live_collab.presence.sync.metas"),
      summary("live_collab.presence.sync.coalesced_diffs")

  Avoid tagging metrics with `:topic` or `:client_id` unless your backend can
  handle one time series per document or per tab.

  ## Logging

  `attach_default_logger/1` logs the operationally relevant events.
  """

  require Logger

  @prefix :live_collab

  @events [
    [:session, :start],
    [:session, :stop],
    [:presence, :sync],
    [:lock, :claimed],
    [:lock, :released],
    [:lock, :denied],
    [:lock, :lost],
    [:event, :rate_limited],
    [:event, :rejected],
    [:spotlight, :started],
    [:spotlight, :stopped],
    [:spotlight, :unauthorized],
    [:status, :changed],
    [:lock, :requested],
    [:lock, :handed_off],
    [:lock, :handoff_declined],
    [:field, :changes_broadcast],
    [:field, :conflict]
  ]

  @logger_handler_id "live-collab-default-logger"

  @doc """
  Returns every event name LiveCollab emits, for use with
  `:telemetry.attach_many/4`.
  """
  @spec events() :: [[atom(), ...]]
  def events, do: Enum.map(@events, &[@prefix | &1])

  @doc """
  Attaches a handler that logs security- and operations-relevant events:

    * `:rejected` events and `:unauthorized` spotlight attempts (`:warning`);
    * the *first* rate-limited event of each flood, and every 1000th after that
      (`:warning`), so a flooding client cannot flood your logs;
    * lost locks (`:info`);
    * session start/stop and lock claims/releases (`:debug`).

  ## Options

    * `:level` - overrides the level of every message (default: per event, as above).

  Returns `:ok`, or `{:error, :already_exists}` if already attached.
  """
  @spec attach_default_logger(keyword()) :: :ok | {:error, :already_exists}
  def attach_default_logger(opts \\ []) do
    :telemetry.attach_many(@logger_handler_id, events(), &__MODULE__.handle_log_event/4, opts)
  end

  @doc "Detaches the handler installed by `attach_default_logger/1`."
  @spec detach_default_logger() :: :ok | {:error, :not_found}
  def detach_default_logger, do: :telemetry.detach(@logger_handler_id)

  @doc false
  def handle_log_event([@prefix | event], measurements, metadata, opts) do
    case log_message(event, measurements, metadata) do
      nil ->
        :ok

      {level, message} ->
        Logger.log(Keyword.get(opts, :level, level), message)
    end
  end

  defp log_message([:event, :rejected], _m, meta) do
    {:warning,
     "[LiveCollab] rejected #{inspect(meta.event)} from #{meta.client_id} on #{meta.topic}: #{inspect(meta.reason)}"}
  end

  defp log_message([:event, :rate_limited], _m, %{consecutive: n} = meta)
       when n == 1 or rem(n, 1000) == 0 do
    {:warning,
     "[LiveCollab] rate limited #{inspect(meta.event)} (#{meta.bucket} bucket, #{n} consecutive) from #{meta.client_id} on #{meta.topic}"}
  end

  defp log_message([:event, :rate_limited], _m, _meta), do: nil

  defp log_message([:spotlight, :unauthorized], _m, meta) do
    {:warning,
     "[LiveCollab] unauthorized spotlight #{meta.action} by #{meta.client_id} on #{meta.topic}"}
  end

  defp log_message([:lock, :lost], _m, meta) do
    {:info,
     "[LiveCollab] #{meta.client_id} lost lock on #{inspect(meta.field)} to #{meta.winner_client_id} on #{meta.topic}"}
  end

  defp log_message([:lock, action], _m, meta)
       when action in [:requested, :handed_off, :handoff_declined] do
    {:debug,
     "[LiveCollab] lock #{action} on #{inspect(meta.field)} by #{meta.client_id} on #{meta.topic}"}
  end

  defp log_message([:field, :conflict], _m, meta) do
    {:info,
     "[LiveCollab] #{meta.client_id} was editing #{inspect(meta.field)} when #{meta.by_client_id} saved it on #{meta.topic}"}
  end

  defp log_message([:lock, action], _m, meta) when action in [:claimed, :released, :denied] do
    {:debug,
     "[LiveCollab] lock #{action} on #{inspect(meta.field)} by #{meta.client_id} on #{meta.topic}"}
  end

  defp log_message([:status, :changed], _m, meta) do
    {:debug, "[LiveCollab] #{meta.client_id} is #{meta.status} on #{meta.topic}"}
  end

  defp log_message([:session, action], _m, meta) do
    {:debug,
     "[LiveCollab] session #{action} #{meta.client_id} (user #{meta.user_key}) on #{meta.topic}"}
  end

  defp log_message(_event, _measurements, _metadata), do: nil

  @doc false
  @spec execute([atom(), ...], map(), map()) :: :ok
  def execute(event, measurements, metadata) do
    :telemetry.execute([@prefix | event], measurements, metadata)
  end
end
