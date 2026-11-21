defmodule LiveCollab.Integration.FieldLockTest do
  @moduledoc """
  Advisory field locks end-to-end: claims, releases, contention, tie-breaks and
  multi-tab behaviour against a real Phoenix.Presence.
  """
  use LiveCollab.CollabCase, async: true

  alias LiveCollab.Field
  alias LiveCollab.Test.Presence

  @alice %{id: "alice", name: "Alice"}
  @bob %{id: "bob", name: "Bob"}

  defp holder(view, field), do: get_in(assigns(view), [:collab_locks, field, :client_id])

  describe "claim and release" do
    test "focus claims a field; peers see the lock; blur releases it" do
      doc = unique_doc()
      alice = join(doc, @alice)
      bob = join(doc, @bob)
      alice_id = assigns(alice).collab_client_id

      render_hook(alice, "live_collab:field_focus", %{"field" => "order.name"})
      assert assigns(alice).collab_editing_field == "order.name"
      eventually(fn -> holder(bob, "order.name") == alice_id end)
      assert render(bob) =~ ~s(id="lock-order.name")

      render_hook(alice, "live_collab:field_blur", %{"field" => "order.name"})
      assert assigns(alice).collab_editing_field == nil
      eventually(fn -> assigns(bob).collab_locks == %{} end)
    end

    test "blur without a field name releases the current claim" do
      doc = unique_doc()
      alice = join(doc, @alice)

      render_hook(alice, "live_collab:field_focus", %{"field" => "title"})
      render_hook(alice, "live_collab:field_blur", %{})

      assert Field.extract_locks(presence_list(doc)) == %{}
    end

    test "regression: a delayed blur of the previous field does not release the new one" do
      # The JS hook debounces blur by 80ms. Tabbing A -> B therefore sends
      # focus(B) *before* blur(A). Previously blur ignored its field and dropped
      # the lock on B while the user was typing in it.
      doc = unique_doc()
      alice = join(doc, @alice)

      render_hook(alice, "live_collab:field_focus", %{"field" => "field_a"})
      render_hook(alice, "live_collab:field_focus", %{"field" => "field_b"})
      render_hook(alice, "live_collab:field_blur", %{"field" => "field_a"})

      assert assigns(alice).collab_editing_field == "field_b"
      assert %{"field_b" => _} = Field.extract_locks(presence_list(doc))
    end

    test "switching fields moves the claim atomically" do
      doc = unique_doc()
      alice = join(doc, @alice)

      render_hook(alice, "live_collab:field_focus", %{"field" => "field_a"})
      render_hook(alice, "live_collab:field_focus", %{"field" => "field_b"})

      assert Map.keys(Field.extract_locks(presence_list(doc))) == ["field_b"]
    end

    test "re-focusing the held field neither re-writes Presence nor resets seniority" do
      doc = unique_doc()
      alice = join(doc, @alice)
      capture_telemetry(alice, [[:live_collab, :lock, :claimed]])

      render_hook(alice, "live_collab:field_focus", %{"field" => "title"})
      %{"title" => %{acquired_at: acquired_at}} = Field.extract_locks(presence_list(doc))

      render_hook(alice, "live_collab:field_focus", %{"field" => "title"})
      render_hook(alice, "live_collab:field_focus", %{"field" => "title"})

      assert %{"title" => %{acquired_at: ^acquired_at}} = Field.extract_locks(presence_list(doc))
      assert_received {:telemetry, [:live_collab, :lock, :claimed], _, %{field: "title"}}
      refute_received {:telemetry, [:live_collab, :lock, :claimed], _, _}
    end
  end

  describe "contention" do
    test "focusing a field held by another collaborator is denied immediately" do
      doc = unique_doc()
      alice = join(doc, @alice)
      bob = join(doc, @bob)
      alice_id = assigns(alice).collab_client_id

      render_hook(alice, "live_collab:field_focus", %{"field" => "title"})
      eventually(fn -> holder(bob, "title") == alice_id end)

      render_hook(bob, "live_collab:field_focus", %{"field" => "title"})

      assert_push_event(bob, "live_collab:lock_lost", %{field: "title", locked_by: "Alice"})
      assert assigns(bob).collab_editing_field == nil
      # Bob never wrote a competing claim into Presence.
      assert %{metas: [%{field: nil}]} = presence_list(doc)["bob"]
    end

    test "simultaneous claims converge on exactly one holder everywhere" do
      doc = unique_doc()
      views = for i <- 1..6, do: join(doc, %{id: "u#{i}", name: "User #{i}"})

      for view <- views do
        eventually(fn -> length(assigns(view).collab_users) == 6 end)
      end

      # Fire all claims back-to-back, before any presence_diff can be applied.
      for view <- views, do: render_hook(view, "live_collab:field_focus", %{"field" => "total"})

      # Invariant 1: every LiveView agrees on the same single holder.
      eventually(fn ->
        holders = Enum.map(views, &holder(&1, "total"))
        Enum.uniq(holders) |> length() == 1 and hd(holders) != nil
      end)

      winner = holder(hd(views), "total")

      # Invariant 2: only the winner still believes it is editing.
      eventually(fn ->
        Enum.count(views, &(assigns(&1).collab_editing_field == "total")) == 1
      end)

      # Invariant 3: every loser was told (lock_lost via denial or tie-break).
      for view <- views, assigns(view).collab_client_id != winner do
        assert_push_event(view, "live_collab:lock_lost", %{field: "total"})
      end
    end

    test "a claim that loses the deterministic tie-break is revoked with lock_lost" do
      # Simulates a claim that was made concurrently on another node (or the
      # other side of a partition) and is only now replicated: it carries an
      # earlier acquired_at, so it wins on every node.
      doc = unique_doc()
      alice = join(doc, @alice)
      capture_telemetry(alice, [[:live_collab, :lock, :lost]])

      render_hook(alice, "live_collab:field_focus", %{"field" => "title"})

      remote =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      on_exit(fn -> send(remote, :stop) end)

      {:ok, _} =
        Presence.track(remote, topic_for(doc), "remote_user", %{
          client_id: "cli_remote",
          user_id: "remote_user",
          user_name: "Remote",
          field: "title",
          acquired_at: 1_000
        })

      assert_push_event(alice, "live_collab:lock_lost", %{field: "title", locked_by: "Remote"})
      eventually(fn -> assigns(alice).collab_editing_field == nil end)

      assert_receive {:telemetry, [:live_collab, :lock, :lost], _,
                      %{field: "title", winner_client_id: "cli_remote"}}
    end

    test "the lock passes to nobody when the holder leaves; others can then claim it" do
      doc = unique_doc()
      alice = join(doc, @alice)
      bob = join(doc, @bob)

      render_hook(alice, "live_collab:field_focus", %{"field" => "title"})
      eventually(fn -> holder(bob, "title") != nil end)

      GenServer.stop(alice.pid, :normal)
      eventually(fn -> assigns(bob).collab_locks == %{} end)

      render_hook(bob, "live_collab:field_focus", %{"field" => "title"})
      assert assigns(bob).collab_editing_field == "title"
    end
  end

  describe "multi-tab" do
    test "a second tab of the same user is locked out of a field held by the first" do
      doc = unique_doc()
      tab1 = join(doc, @alice)
      tab2 = join(doc, @alice)

      render_hook(tab1, "live_collab:field_focus", %{"field" => "title"})
      eventually(fn -> holder(tab2, "title") == assigns(tab1).collab_client_id end)

      render_hook(tab2, "live_collab:field_focus", %{"field" => "title"})
      assert_push_event(tab2, "live_collab:lock_lost", %{field: "title"})
    end

    test "each tab updates only its own Presence meta" do
      doc = unique_doc()
      tab1 = join(doc, @alice)
      tab2 = join(doc, @alice)

      render_hook(tab2, "live_collab:field_focus", %{"field" => "body"})

      metas = presence_list(doc)["alice"].metas
      by_client = Map.new(metas, &{&1.client_id, &1.field})
      assert by_client[assigns(tab1).collab_client_id] == nil
      assert by_client[assigns(tab2).collab_client_id] == "body"
    end
  end

  describe "server-side enforcement" do
    test "validate_not_locked/5 blocks a submit for a field held by someone else" do
      doc = unique_doc()
      alice = join(doc, @alice)
      bob = join(doc, @bob)

      render_hook(alice, "live_collab:field_focus", %{"field" => "name"})
      eventually(fn -> holder(bob, "name") != nil end)

      bob_assigns = assigns(bob)

      changeset =
        LiveCollab.validate_not_locked(
          %{errors: []},
          :name,
          bob_assigns.collab_locks,
          bob_assigns.collab_client_id
        )

      assert [name: {"is currently being edited by Alice", []}] = changeset.errors

      alice_assigns = assigns(alice)

      assert %{errors: []} =
               LiveCollab.validate_not_locked(
                 %{errors: []},
                 :name,
                 alice_assigns.collab_locks,
                 alice_assigns.collab_client_id
               )
    end
  end
end
