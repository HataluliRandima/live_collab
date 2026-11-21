defmodule LiveCollab.BroadcastChangesTest do
  use ExUnit.Case, async: true

  # Not connected / not tracked: validation still runs, broadcasting is a no-op.
  defp socket, do: %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}

  test "valid changes on an untracked socket are a no-op" do
    assert %Phoenix.LiveView.Socket{} =
             LiveCollab.broadcast_changes(socket(), %{
               "title" => "x",
               "n" => 1,
               "ok" => true,
               "gone" => nil
             })

    assert %Phoenix.LiveView.Socket{} = LiveCollab.broadcast_changes(socket(), title: "x")
  end

  test "invalid field ids, values and sizes raise" do
    assert_raise ArgumentError, ~r/invalid field id/, fn ->
      LiveCollab.broadcast_changes(socket(), %{"<b>" => "x"})
    end

    assert_raise ArgumentError, ~r/must be nil, a boolean/, fn ->
      LiveCollab.broadcast_changes(socket(), %{"title" => %{"nested" => 1}})
    end

    assert_raise ArgumentError, ~r/at most 65536 bytes/, fn ->
      LiveCollab.broadcast_changes(socket(), %{"title" => String.duplicate("a", 65_537)})
    end

    assert_raise ArgumentError, ~r/at most 100 fields/, fn ->
      LiveCollab.broadcast_changes(socket(), Map.new(1..101, &{"f#{&1}", &1}))
    end

    assert_raise ArgumentError, ~r/map or keyword list/, fn ->
      LiveCollab.broadcast_changes(socket(), "title")
    end
  end
end
