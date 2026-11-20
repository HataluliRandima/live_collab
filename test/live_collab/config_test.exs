defmodule LiveCollab.ConfigTest do
  use ExUnit.Case, async: true
  alias LiveCollab.Config

  test "defaults" do
    config = Config.get()
    assert config.topic_prefix == "live_collab"
    assert config.telemetry_rate_per_sec == 50
    assert config.telemetry_burst_limit == 60
    assert config.presence_rate_per_sec == 20
    assert config.presence_burst_limit == 40
    assert config.clock_skew_tolerance_ms == 500
  end

  test "overrides win over defaults; unknown keys are ignored" do
    config = Config.get(topic_prefix: "collab", client_id: "x", unknown: true)
    assert config.topic_prefix == "collab"
  end

  describe "invalid values raise ArgumentError naming the key" do
    for {key, value} <- [
          topic_prefix: "",
          topic_prefix: :atom,
          max_field_id_length: 0,
          max_field_id_length: 100_000,
          max_field_id_length: "255",
          telemetry_rate_per_sec: 0,
          telemetry_rate_per_sec: -5,
          telemetry_burst_limit: 0,
          presence_rate_per_sec: nil,
          presence_burst_limit: 0.5,
          clock_skew_tolerance_ms: -1,
          clock_skew_tolerance_ms: 1.5,
          presence: "MyApp.Presence",
          pubsub: true
        ] do
      test "#{key}: #{inspect(value)}" do
        assert_raise ArgumentError, ~r/#{unquote(key)}/, fn ->
          Config.get([{unquote(key), unquote(Macro.escape(value))}])
        end
      end
    end
  end

  describe "topic/2" do
    test "builds topics from tuples, strings and other terms" do
      config = Config.get()
      assert Config.topic(config, {"order", 42}) == "live_collab:order:42"
      assert Config.topic(config, "doc:1") == "live_collab:doc:1"
      assert Config.topic(config, 7) == "live_collab:7"
    end
  end

  describe "pubsub_server!/1" do
    test "uses the configured pubsub" do
      assert Config.pubsub_server!(Config.get(pubsub: MyApp.PubSub)) == MyApp.PubSub
    end

    test "falls back to the Presence module's :pubsub_server" do
      config = Config.get(presence: LiveCollab.Test.Presence)
      assert Config.pubsub_server!(config) == LiveCollab.Test.PubSub
    end

    test "raises with instructions when it cannot be determined" do
      assert_raise ArgumentError, ~r/config :live_collab, pubsub:/, fn ->
        Config.pubsub_server!(Config.get(presence: String))
      end
    end
  end
end
