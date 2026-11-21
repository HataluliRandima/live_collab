defmodule LiveCollab.PresenceDiffTest do
  use ExUnit.Case, async: true
  import LiveCollab.LiveView, only: [apply_presence_diff: 2]

  defp meta(ref, extra \\ %{}), do: Map.merge(%{phx_ref: ref, client_id: "cli_#{ref}"}, extra)

  test "joins add entries and metas" do
    entries = apply_presence_diff(%{}, %{joins: %{"u1" => %{metas: [meta("a")]}}, leaves: %{}})
    assert entries == %{"u1" => %{metas: [meta("a")]}}

    entries =
      apply_presence_diff(entries, %{joins: %{"u1" => %{metas: [meta("b")]}}, leaves: %{}})

    assert entries["u1"].metas == [meta("a"), meta("b")]
  end

  test "leaves remove metas by phx_ref and drop empty keys" do
    entries = %{"u1" => %{metas: [meta("a"), meta("b")]}}

    entries =
      apply_presence_diff(entries, %{joins: %{}, leaves: %{"u1" => %{metas: [meta("a")]}}})

    assert entries["u1"].metas == [meta("b")]

    entries =
      apply_presence_diff(entries, %{joins: %{}, leaves: %{"u1" => %{metas: [meta("b")]}}})

    assert entries == %{}
  end

  test "an update (join new ref + leave old ref) replaces the meta" do
    entries = %{"u1" => %{metas: [meta("a", %{field: nil})]}}

    diff = %{
      joins: %{"u1" => %{metas: [meta("b", %{field: "title", phx_ref_prev: "a"})]}},
      leaves: %{"u1" => %{metas: [meta("a", %{field: nil})]}}
    }

    assert %{"u1" => %{metas: [%{phx_ref: "b", field: "title"}]}} =
             apply_presence_diff(entries, diff)
  end

  test "re-applying a diff already reflected in the state is idempotent" do
    diff = %{joins: %{"u1" => %{metas: [meta("a")]}}, leaves: %{"u2" => %{metas: [meta("z")]}}}
    entries = %{"u1" => %{metas: [meta("a")]}}
    assert apply_presence_diff(entries, diff) == entries
  end

  test "malformed diffs are ignored" do
    entries = %{"u1" => %{metas: [meta("a")]}}
    assert apply_presence_diff(entries, nil) == entries
    assert apply_presence_diff(entries, %{joins: :bad, leaves: %{}}) == entries
    assert apply_presence_diff(entries, %{joins: %{"x" => :bad}, leaves: %{"y" => 1}}) == entries
  end
end
