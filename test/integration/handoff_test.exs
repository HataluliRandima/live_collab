defmodule LiveCollab.Integration.HandoffTest do
  @moduledoc "\"Ask to edit\" lock handoff end-to-end against a real Phoenix.Presence."
  use LiveCollab.CollabCase, async: true

  alias LiveCollab.Field

  @alice %{id: "alice", name: "Alice"}
  @bob %{id: "bob", name: "Bob"}

  # Alice holds "title"; Bob sees the lock.
  defp held_by_alice do
    doc = unique_doc()
    alice = join(doc, @alice)
    bob = join(doc, @bob)
    render_hook(alice, "live_collab:field_focus", %{"field" => "title"})
    alice_id = assigns(alice).collab_client_id
    eventually(fn -> get_in(assigns(bob), [:collab_locks, "title", :client_id]) == alice_id end)
    {doc, alice, bob}
  end

  test "a request reaches the holder and marks the ask as pending" do
    {_doc, alice, bob} = held_by_alice()
    bob_id = assigns(bob).collab_client_id
    capture_telemetry(bob, [[:live_collab, :lock, :requested]])

    render_hook(bob, "live_collab:lock_request", %{"field" => "title"})

    assert assigns(bob).collab_lock_asks == %{"title" => :pending}
    assert_push_event(alice, "live_collab:lock_requested", %{field: "title", requested_by: "Bob"})

    assert %{"title" => [%{client_id: ^bob_id, user_name: "Bob"}]} =
             assigns(alice).collab_lock_requests

    assert_received {:telemetry, [:live_collab, :lock, :requested], _, %{field: "title"}}
  end

  test "handing over releases the lock and lets the requester claim it immediately" do
    {doc, alice, bob} = held_by_alice()
    bob_id = assigns(bob).collab_client_id
    render_hook(bob, "live_collab:lock_request", %{"field" => "title"})
    assert_push_event(alice, "live_collab:lock_requested", _)

    render_hook(alice, "live_collab:lock_handoff", %{
      "field" => "title",
      "to" => bob_id,
      "accept" => "true"
    })

    assert assigns(alice).collab_editing_field == nil
    assert assigns(alice).collab_lock_requests == %{}
    assert_push_event(bob, "live_collab:lock_granted", %{field: "title", granted_by: "Alice"})
    assert assigns(bob).collab_lock_asks == %{}

    # The hook focuses the input next; the claim must not be refused because of
    # a stale lock that Bob's throttled rebuild has not removed yet.
    render_hook(bob, "live_collab:field_focus", %{"field" => "title"})
    refute_push_event(bob, "live_collab:lock_lost", _, 20)
    assert assigns(bob).collab_editing_field == "title"

    eventually(fn ->
      match?(%{"title" => %{client_id: ^bob_id}}, Field.extract_locks(presence_list(doc)))
    end)
  end

  test "declining keeps the lock and tells the requester" do
    {_doc, alice, bob} = held_by_alice()
    bob_id = assigns(bob).collab_client_id
    render_hook(bob, "live_collab:lock_request", %{"field" => "title"})
    assert_push_event(alice, "live_collab:lock_requested", _)

    render_hook(alice, "live_collab:lock_handoff", %{
      "field" => "title",
      "to" => bob_id,
      "accept" => "false"
    })

    assert assigns(alice).collab_editing_field == "title"
    assert assigns(alice).collab_lock_requests == %{}
    eventually(fn -> assigns(bob).collab_lock_asks == %{"title" => :declined} end)
    refute_push_event(bob, "live_collab:lock_granted", _, 20)
  end

  test "repeated asks while pending send a single request" do
    {_doc, alice, bob} = held_by_alice()

    for _ <- 1..5, do: render_hook(bob, "live_collab:lock_request", %{"field" => "title"})

    assert_push_event(alice, "live_collab:lock_requested", _)
    refute_push_event(alice, "live_collab:lock_requested", _, 30)
    assert [_one] = assigns(alice).collab_lock_requests["title"]
  end

  test "only the addressed holder records a request" do
    {doc, _alice, bob} = held_by_alice()
    carol = join(doc, %{id: "carol", name: "Carol"})
    eventually(fn -> Map.has_key?(assigns(carol).collab_locks, "title") end)

    render_hook(bob, "live_collab:lock_request", %{"field" => "title"})

    refute_push_event(carol, "live_collab:lock_requested", _, 30)
    assert assigns(carol).collab_lock_requests == %{}
  end

  test "asking for a free field or your own field is rejected" do
    {_doc, alice, bob} = held_by_alice()
    capture_telemetry(alice, [[:live_collab, :event, :rejected]])

    render_hook(alice, "live_collab:lock_request", %{"field" => "title"})
    render_hook(alice, "live_collab:lock_request", %{"field" => "free_field"})
    render_hook(alice, "live_collab:lock_request", %{"field" => "<script>"})

    assert_received {:telemetry, _, _, %{event: "lock_request", reason: :not_locked_by_other}}
    assert_received {:telemetry, _, _, %{event: "lock_request", reason: :not_locked_by_other}}
    assert_received {:telemetry, _, _, %{event: "lock_request", reason: :disallowed_characters}}
    refute_push_event(bob, "live_collab:lock_requested", _, 20)
  end

  test "security: a handoff can only answer a request that was actually received" do
    {_doc, alice, bob} = held_by_alice()
    capture_telemetry(alice, [[:live_collab, :event, :rejected]])

    render_hook(alice, "live_collab:lock_handoff", %{
      "field" => "title",
      "to" => assigns(bob).collab_client_id,
      "accept" => "true"
    })

    assert_received {:telemetry, _, _, %{event: "lock_handoff", reason: :no_such_request}}
    assert assigns(alice).collab_editing_field == "title"
    refute_push_event(bob, "live_collab:lock_granted", _, 20)
  end

  test "stale requests and asks are dropped when the holder releases or the requester leaves" do
    {_doc, alice, bob} = held_by_alice()
    render_hook(bob, "live_collab:lock_request", %{"field" => "title"})
    assert_push_event(alice, "live_collab:lock_requested", _)

    GenServer.stop(bob.pid, :normal)
    eventually(fn -> assigns(alice).collab_lock_requests == %{} end)

    # And the other way round: the holder releases, so the requester's ask is moot.
    {_doc, alice2, bob2} = held_by_alice()
    render_hook(bob2, "live_collab:lock_request", %{"field" => "title"})
    render_hook(alice2, "live_collab:field_blur", %{"field" => "title"})

    assert assigns(alice2).collab_lock_requests == %{}
    eventually(fn -> assigns(bob2).collab_lock_asks == %{} end)
  end
end
