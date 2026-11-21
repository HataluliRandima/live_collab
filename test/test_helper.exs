Application.put_env(:live_collab, LiveCollab.Test.Endpoint,
  url: [host: "localhost"],
  secret_key_base: String.duplicate("live_collab_test_secret_", 4),
  live_view: [signing_salt: "live_collab_lv_salt"],
  pubsub_server: LiveCollab.Test.PubSub,
  render_errors: [formats: [html: LiveCollab.Test.ErrorHTML], layout: false],
  server: false
)

{:ok, _} =
  Supervisor.start_link(
    [
      {Phoenix.PubSub, name: LiveCollab.Test.PubSub},
      LiveCollab.Test.Presence,
      LiveCollab.Test.Endpoint
    ],
    strategy: :one_for_one
  )

Logger.configure(level: :warning)

# Multi-node tests start :peer nodes and need distributed Erlang (epmd).
# They run with `mix test --include distributed`. Benchmarks (test/bench) run
# with `mix test test/bench --include benchmark`.
ExUnit.start(exclude: [:distributed, :benchmark])
