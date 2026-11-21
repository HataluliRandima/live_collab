defmodule LiveCollab.Integration.ChangesTest do
  @moduledoc "Conflict-aware forms: broadcast_changes/3 end-to-end."
  use LiveCollab.CollabCase, async: true

  @alice %{id: "alice", name: "Alice", color: "#DC2626"}
  @bob %{id: "bob", name: "Bob"}

  defp pair(bob_opts \\ []) do
    doc = unique_doc()
    alice = join(doc, @alice)
    bob = join(doc, @bob, bob_opts)
    eventually(fn -> length(assigns(alice).collab_users) == 2 end)
    {alice, bob}
  end

  test "collaborators who are not editing the field get the new value" do
    {alice, bob} = pair()

    render_click(alice, "save", %{"changes" => %{"title" => "New title", "qty" => 3}})

    assert_push_event(bob, "live_collab:field_changed", %{
      field: "title",
      value: "New title",
      by: "Alice",
      by_color: "#DC2626"
    })

    assert_push_event(bob, "live_collab:field_changed", %{field: "qty", value: 3})
    assert assigns(bob).collab_remote_changes == %{}
    refute_push_event(alice, "live_collab:field_changed", _, 20)
  end

  test "a collaborator editing the field gets a conflict instead, until dismissed" do
    {alice, bob} = pair()
    capture_telemetry(bob, [[:live_collab, :field, :conflict]])
    render_hook(bob, "live_collab:field_focus", %{"field" => "summary"})

    render_click(alice, "save", %{"changes" => %{"summary" => "Alice's version"}})

    assert_push_event(bob, "live_collab:field_conflict", %{
      field: "summary",
      value: "Alice's version"
    })

    refute_push_event(bob, "live_collab:field_changed", %{field: "summary"}, 20)

    assert %{"summary" => %{value: "Alice's version", by_name: "Alice", by_color: "#DC2626"}} =
             assigns(bob).collab_remote_changes

    assert_received {:telemetry, [:live_collab, :field, :conflict], _, %{field: "summary"}}

    render_hook(bob, "live_collab:dismiss_change", %{"field" => "summary"})
    assert assigns(bob).collab_remote_changes == %{}
    assert_push_event(bob, "live_collab:change_dismissed", %{field: "summary"})
  end

  test "notify_changes delivers a message the app can use to reload its data" do
    {alice, bob} = pair(collab_opts: [notify_changes: true])

    render_click(alice, "save", %{"changes" => %{"title" => "T"}})

    eventually(fn ->
      match?(
        [{:remote_changes, %{changes: %{"title" => "T"}, by: %{name: "Alice"}}} | _],
        assigns(bob).app_events
      )
    end)
  end

  test "without notify_changes the app receives no message" do
    {alice, bob} = pair()
    render_click(alice, "save", %{"changes" => %{"title" => "T"}})
    assert_push_event(bob, "live_collab:field_changed", _)
    assert assigns(bob).app_events == []
  end

  test "dismissing a change that does not exist is rejected" do
    {_alice, bob} = pair()
    capture_telemetry(bob, [[:live_collab, :event, :rejected]])
    render_hook(bob, "live_collab:dismiss_change", %{"field" => "nope"})
    assert_received {:telemetry, _, _, %{event: "dismiss_change", reason: :no_such_change}}
  end
end
