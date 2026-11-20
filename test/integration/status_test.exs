defmodule LiveCollab.Integration.StatusTest do
  @moduledoc "Away / idle status end-to-end against a real Phoenix.Presence."
  use LiveCollab.CollabCase, async: true

  @alice %{id: "alice", name: "Alice"}
  @bob %{id: "bob", name: "Bob"}

  defp status_of(view, user_id) do
    Enum.find_value(assigns(view).collab_users, &(&1.id == user_id && &1.status))
  end

  test "collaborators start active, see each other go away and come back" do
    doc = unique_doc()
    alice = join(doc, @alice)
    bob = join(doc, @bob)
    eventually(fn -> status_of(bob, "alice") == :active end)

    render_hook(alice, "live_collab:status", %{"status" => "away"})
    eventually(fn -> status_of(bob, "alice") == :away end)

    render_hook(alice, "live_collab:status", %{"status" => "active"})
    eventually(fn -> status_of(bob, "alice") == :active end)
  end

  test "a user with one away tab and one active tab is active" do
    doc = unique_doc()
    tab1 = join(doc, @alice)
    _tab2 = join(doc, @alice)
    observer = join(doc, @bob)

    render_hook(tab1, "live_collab:status", %{"status" => "away"})
    eventually(fn -> match?(%{metas: [_, _]}, presence_list(doc)["alice"]) end)

    eventually(fn ->
      Enum.any?(presence_list(doc)["alice"].metas, &(&1.status == :away))
    end)

    assert status_of(observer, "alice") == :active
  end

  test "repeated statuses do not write to Presence; changes emit telemetry" do
    doc = unique_doc()
    alice = join(doc, @alice)
    capture_telemetry(alice, [[:live_collab, :status, :changed]])

    render_hook(alice, "live_collab:status", %{"status" => "active"})
    render_hook(alice, "live_collab:status", %{"status" => "away"})
    render_hook(alice, "live_collab:status", %{"status" => "away"})

    assert_received {:telemetry, [:live_collab, :status, :changed], _, %{status: :away}}
    refute_received {:telemetry, [:live_collab, :status, :changed], _, _}
    assert %{metas: [%{status: :away}]} = presence_list(doc)["alice"]
  end

  test "invalid statuses are rejected" do
    doc = unique_doc()
    alice = join(doc, @alice)
    capture_telemetry(alice, [[:live_collab, :event, :rejected]])

    for bad <- ["asleep", :away, 1, nil, %{}] do
      render_hook(alice, "live_collab:status", %{"status" => bad})
    end

    render_hook(alice, "live_collab:status", %{})

    assert_received {:telemetry, _, _, %{event: "status", reason: :invalid_status}}
    assert_received {:telemetry, _, _, %{event: "status", reason: :invalid_params}}
    assert %{metas: [%{status: :active}]} = presence_list(doc)["alice"]
  end

  test "status changes share the presence rate-limit bucket" do
    doc = unique_doc()

    alice =
      join(doc, @alice, collab_opts: [presence_rate_per_sec: 1, presence_burst_limit: 2])

    capture_telemetry(alice, [[:live_collab, :event, :rate_limited]])

    for i <- 1..10 do
      render_hook(alice, "live_collab:status", %{
        "status" => if(rem(i, 2) == 0, do: "active", else: "away")
      })
    end

    assert_received {:telemetry, _, _, %{event: "status", bucket: :presence}}
  end
end
