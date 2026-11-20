defmodule LiveCollab.Test.ClusterPresence do
  @moduledoc false
  # Presence used only on :peer nodes in distributed tests. A separate PubSub
  # name keeps peer clusters isolated from the test node's own Presence.
  use Phoenix.Presence, otp_app: :live_collab, pubsub_server: :live_collab_cluster_pubsub
end

defmodule LiveCollab.Test.ClusterNode do
  @moduledoc false
  # Runs *on peer nodes*. Starts PubSub + Presence and hosts collaborator
  # processes that use LiveCollab's Presence-level API exactly as a LiveView
  # process does (track, update_field, extract_locks).

  alias LiveCollab.Field
  alias LiveCollab.Test.ClusterPresence

  @doc "Starts PubSub and Presence on this node under an unlinked supervisor."
  def boot(tracker_opts) do
    Logger.configure(level: :error)
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
    {:ok, _} = Application.ensure_all_started(:telemetry)
    parent = self()

    spawn(fn ->
      {:ok, sup} =
        Supervisor.start_link(
          [
            {Phoenix.PubSub, name: :live_collab_cluster_pubsub},
            {ClusterPresence, tracker_opts}
          ],
          strategy: :one_for_one
        )

      send(parent, {:booted, sup})
      Process.sleep(:infinity)
    end)

    receive do
      {:booted, _sup} -> :ok
    after
      5_000 -> {:error, :boot_timeout}
    end
  end

  @doc "Starts a collaborator process tracked on `topic`; returns its pid."
  def start_client(topic, user, client_id) do
    parent = self()

    pid =
      spawn(fn ->
        {:ok, _} = LiveCollab.Presence.track(ClusterPresence, self(), topic, user, client_id)
        send(parent, {:tracked, self()})
        client_loop(topic, user, client_id)
      end)

    receive do
      {:tracked, ^pid} -> pid
    after
      5_000 -> raise "client did not track"
    end
  end

  @doc "Synchronously sends a command to a collaborator process."
  def command(pid, cmd) do
    ref = make_ref()
    send(pid, {:cmd, self(), ref, cmd})

    receive do
      {^ref, reply} -> reply
    after
      5_000 -> {:error, :timeout}
    end
  end

  @doc "Locks as resolved on this node."
  def locks(topic, tolerance \\ 500) do
    Field.extract_locks(ClusterPresence.list(topic), clock_skew_tolerance_ms: tolerance)
  end

  @doc "Presence keys visible on this node."
  def keys(topic), do: topic |> ClusterPresence.list() |> Map.keys() |> Enum.sort()

  defp client_loop(topic, user, client_id) do
    receive do
      {:cmd, from, ref, {:focus, field}} ->
        reply =
          LiveCollab.Presence.update_field(
            ClusterPresence,
            self(),
            topic,
            to_string(user.id),
            field,
            client_id
          )

        send(from, {ref, reply})
        client_loop(topic, user, client_id)

      {:cmd, from, ref, {:claim_at, field, acquired_at}} ->
        # Claim with an explicit timestamp, to model a node whose clock is skewed.
        reply =
          ClusterPresence.update(self(), topic, to_string(user.id), fn meta ->
            %{meta | field: field, acquired_at: acquired_at}
          end)

        send(from, {ref, reply})
        client_loop(topic, user, client_id)

      {:cmd, from, ref, :stop} ->
        send(from, {ref, :ok})
    end
  end
end
