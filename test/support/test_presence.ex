defmodule LiveCollab.TestSupport.TestPresence do
  @moduledoc """
  In-memory mock for Phoenix.Presence to enable fast, deterministic unit
  and integration testing without requiring a live distributed cluster.
  """

  use Agent

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  def reset! do
    if Process.whereis(__MODULE__) do
      Agent.update(__MODULE__, fn _ -> %{} end)
    else
      start_link()
    end
  end

  def track(pid_or_socket, topic, key, meta) do
    ensure_started()
    pid = extract_pid(pid_or_socket)
    phx_ref = "ref_#{:erlang.unique_integer([:positive])}"
    meta_with_ref = Map.put(meta, :phx_ref, phx_ref)

    Agent.update(__MODULE__, fn state ->
      topic_map = Map.get(state, topic, %{})
      key_entry = Map.get(topic_map, key, %{metas: []})
      new_metas = [meta_with_ref | key_entry.metas]
      new_key_entry = Map.put(key_entry, :metas, new_metas)
      new_topic_map = Map.put(topic_map, key, new_key_entry)
      Map.put(state, topic, new_topic_map)
    end)

    # Monitor pid to clean up on process death (simulating Tracker)
    if is_pid(pid) do
      caller = self()

      spawn(fn ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} ->
            Agent.update(LiveCollab.TestSupport.TestPresence, fn state ->
              topic_map = Map.get(state, topic, %{})

              case Map.get(topic_map, key) do
                nil ->
                  state

                %{metas: metas} ->
                  filtered = Enum.reject(metas, &(&1[:phx_ref] == phx_ref))

                  new_topic_map =
                    if filtered == [] do
                      Map.delete(topic_map, key)
                    else
                      Map.put(topic_map, key, %{metas: filtered})
                    end

                  Map.put(state, topic, new_topic_map)
              end
            end)
        end
      end)
    end

    {:ok, phx_ref}
  end

  def update(_pid_or_socket, topic, key, update_fn) when is_function(update_fn, 1) do
    ensure_started()

    Agent.update(__MODULE__, fn state ->
      topic_map = Map.get(state, topic, %{})

      case Map.get(topic_map, key) do
        nil ->
          state

        %{metas: [current | rest]} ->
          updated_meta = update_fn.(current)
          new_topic_map = Map.put(topic_map, key, %{metas: [updated_meta | rest]})
          Map.put(state, topic, new_topic_map)

        %{metas: []} ->
          state
      end
    end)

    {:ok, "ref_updated"}
  end

  def update(pid_or_socket, topic, key, new_meta) when is_map(new_meta) do
    update(pid_or_socket, topic, key, fn _ -> new_meta end)
  end

  def untrack(_pid_or_socket, topic, key) do
    ensure_started()

    Agent.update(__MODULE__, fn state ->
      topic_map = Map.get(state, topic, %{})
      new_topic_map = Map.delete(topic_map, key)
      Map.put(state, topic, new_topic_map)
    end)

    {:ok, "ref_untracked"}
  end

  def list(topic) do
    ensure_started()

    Agent.get(__MODULE__, fn state ->
      Map.get(state, topic, %{})
    end)
  end

  def __pubsub_server__, do: LiveCollab.TestSupport.TestPubSub

  defp extract_pid(%Phoenix.LiveView.Socket{root_pid: pid}), do: pid
  defp extract_pid(pid) when is_pid(pid), do: pid
  defp extract_pid(_), do: self()

  defp ensure_started do
    unless Process.whereis(__MODULE__) do
      start_link()
    end
  end
end
