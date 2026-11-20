defmodule LiveCollab.TelemetryTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias LiveCollab.Telemetry

  @meta %{topic: "live_collab:doc:1", client_id: "cli_1", user_key: "u1"}

  setup do
    Telemetry.detach_default_logger()
    on_exit(fn -> Telemetry.detach_default_logger() end)
    :ok
  end

  test "events/0 lists every event under the :live_collab prefix" do
    assert [:live_collab, :event, :rejected] in Telemetry.events()
    assert Enum.all?(Telemetry.events(), &match?([:live_collab | _], &1))
    assert length(Telemetry.events()) == length(Enum.uniq(Telemetry.events()))
  end

  test "attach_default_logger/1 is idempotent-safe" do
    assert :ok = Telemetry.attach_default_logger()
    assert {:error, :already_exists} = Telemetry.attach_default_logger()
    assert :ok = Telemetry.detach_default_logger()
  end

  test "logs rejected events as warnings without client payloads" do
    :ok = Telemetry.attach_default_logger()

    log =
      capture_log([level: :warning], fn ->
        Telemetry.execute(
          [:event, :rejected],
          %{count: 1},
          Map.merge(@meta, %{event: "field_focus", reason: :disallowed_characters})
        )
      end)

    assert log =~ "rejected \"field_focus\" from cli_1"
    assert log =~ ":disallowed_characters"
  end

  test "logs only the first and every 1000th rate-limited event of a flood" do
    :ok = Telemetry.attach_default_logger()

    log =
      capture_log([level: :warning], fn ->
        for n <- 1..2_500 do
          Telemetry.execute(
            [:event, :rate_limited],
            %{count: 1},
            Map.merge(@meta, %{event: "cursor_move", bucket: :telemetry, consecutive: n})
          )
        end
      end)

    assert length(String.split(log, "rate limited")) - 1 == 3
  end

  test "the :level option overrides levels" do
    :ok = Telemetry.attach_default_logger(level: :error)

    log =
      capture_log([level: :error], fn ->
        Telemetry.execute(
          [:lock, :lost],
          %{},
          Map.merge(@meta, %{field: "f", winner_client_id: "cli_2"})
        )
      end)

    assert log =~ "lost lock"
  end
end
