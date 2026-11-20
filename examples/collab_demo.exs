# LiveCollab demo: presence, field locks, cursors and a live telemetry panel.
#
#     elixir examples/collab_demo.exs
#
# Then open http://localhost:4000/?name=Alice and http://localhost:4000/?name=Bob
# in two windows. Focus the inputs, move the mouse over the canvas, and watch the
# "Diagnostics" panel: it is fed by LiveCollab.Telemetry events. Focus the same
# input in both windows to see lock claims and denials, or move the mouse quickly
# to see rate limiting (the demo uses a deliberately low telemetry limit).
#
# Requires network access the first time (Mix.install fetches Phoenix and Bandit).
# The LiveCollab JS hooks are served straight from assets/js as ES modules.

Mix.install(
  [
    {:live_collab, path: Path.expand("..", __DIR__)},
    {:phoenix, "~> 1.8"},
    {:phoenix_live_view, "~> 1.1"},
    {:bandit, "~> 1.5"},
    {:jason, "~> 1.4"}
  ],
  config: [
    live_collab: [
      {Demo.Endpoint,
       [
         url: [host: "localhost"],
         http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT", "4000"))],
         adapter: Bandit.PhoenixAdapter,
         server: true,
         secret_key_base: String.duplicate("demo_secret_key_base_", 4),
         live_view: [signing_salt: "demo_lv_salt"],
         pubsub_server: Demo.PubSub,
         check_origin: false
       ]},
      presence: Demo.Presence,
      telemetry_rate_per_sec: 15,
      telemetry_burst_limit: 20
    ]
  ]
)

defmodule Demo.Presence do
  use Phoenix.Presence, otp_app: :live_collab, pubsub_server: Demo.PubSub
end

defmodule Demo.Diagnostics do
  @moduledoc "Forwards LiveCollab telemetry to a PubSub topic shown in the UI."
  @topic "demo:diagnostics"

  def topic, do: @topic

  def attach do
    :telemetry.attach_many("demo-diagnostics", LiveCollab.Telemetry.events(), &__MODULE__.handle/4, nil)
  end

  # Runs in the LiveView process that emitted the event: keep it cheap.
  def handle([:live_collab | event], measurements, meta, _config) do
    entry = %{
      at: Time.utc_now() |> Time.truncate(:millisecond),
      event: Enum.join(event, "."),
      client: meta[:client_id],
      details: details(event, measurements, meta)
    }

    Phoenix.PubSub.broadcast(Demo.PubSub, @topic, {:diagnostic, entry})
  end

  defp details([:presence, :sync], m, _),
    do: "#{m.users} users, #{m.metas} tabs, #{System.convert_time_unit(m.duration, :native, :microsecond)}µs, coalesced #{m.coalesced_diffs}"

  defp details([:event, :rate_limited], _m, meta), do: "#{meta.event} (#{meta.bucket}, ##{meta.consecutive})"
  defp details([:event, :rejected], _m, meta), do: "#{meta.event}: #{inspect(meta.reason)}"
  defp details([:lock, :lost], _m, meta), do: "#{meta.field} -> #{meta.winner_client_id}"
  defp details([:lock, :denied], _m, meta), do: "#{meta.field} held by #{meta.holder_client_id}"
  defp details([:lock, _], _m, meta), do: to_string(meta[:field])
  defp details([:spotlight, :unauthorized], _m, meta), do: to_string(meta.action)
  defp details(_event, _m, _meta), do: ""
end

defmodule Demo.Layout do
  use Phoenix.Component

  def render("root.html", assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <title>LiveCollab demo</title>
        <style>
          body { font: 14px system-ui, sans-serif; margin: 24px; color: #111827; }
          .grid { display: grid; grid-template-columns: 1fr 380px; gap: 24px; }
          input { padding: 6px 8px; border: 1px solid #d1d5db; border-radius: 6px; width: 260px; }
          input[readonly] { background: #f3f4f6; }
          .canvas { height: 220px; border: 1px dashed #9ca3af; border-radius: 8px; margin-top: 16px; }
          .live-collab-avatar-stack > * { display: inline-flex; margin-right: 4px; }
          .live-collab-avatar-stack div[style] { width: 32px; height: 32px; border-radius: 999px; color: #fff;
            display: inline-flex; align-items: center; justify-content: center; font-weight: 600; }
          .live-collab-field-indicator { display: inline-block; margin-left: 8px; padding: 2px 6px; border-radius: 4px; color: #fff; }
          .live-collab-cursor-layer { position: absolute; inset: 0; pointer-events: none; overflow: hidden; }
          .live-collab-remote-cursor { position: absolute; top: 0; left: 0; }
          .live-collab-cursor-pill { color: #fff; padding: 1px 6px; border-radius: 4px; font-size: 11px; }
          .sr-only { position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(0 0 0 0); }
          table { width: 100%; border-collapse: collapse; font: 12px ui-monospace, monospace; }
          td { padding: 2px 4px; border-bottom: 1px solid #f3f4f6; vertical-align: top; }
        </style>
        <script type="importmap">
          {"imports": {
            "phoenix": "/assets/phoenix/phoenix.mjs",
            "phoenix_live_view": "/assets/phoenix_live_view/phoenix_live_view.esm.js",
            "live_collab": "/assets/live_collab/index.js"
          }}
        </script>
        <script type="module">
          import { Socket } from "phoenix";
          import { LiveSocket } from "phoenix_live_view";
          import { LiveCollabHooks } from "live_collab";

          const csrfToken = document.querySelector("meta[name='csrf-token']").content;
          const liveSocket = new LiveSocket("/live", Socket, {
            params: { _csrf_token: csrfToken },
            hooks: { ...LiveCollabHooks }
          });
          liveSocket.connect();
        </script>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end
end

defmodule Demo.CollabLive do
  use Phoenix.LiveView
  import LiveCollab.Components

  @impl true
  def mount(params, _session, socket) do
    name = params["name"] || "Guest #{:rand.uniform(999)}"
    user = %{id: "#{name}-#{System.unique_integer([:positive])}", name: name, role: params["role"]}

    if connected?(socket), do: Phoenix.PubSub.subscribe(Demo.PubSub, Demo.Diagnostics.topic())

    socket =
      socket
      |> assign(:diagnostics, [])
      |> LiveCollab.track("demo:document", user)

    {:ok, socket}
  end

  @impl true
  def handle_info({:diagnostic, entry}, socket) do
    {:noreply, update(socket, :diagnostics, &Enum.take([entry | &1], 25))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="grid">
      <section>
        <h1>LiveCollab demo</h1>
        <p>
          You are <strong>{@collab_client_id}</strong>.
          Open this page in another window with a different <code>?name=</code>.
        </p>
        <.avatar_stack users={@collab_users} max={6} />

        <h3>Advisory field locks</h3>
        <p :for={field <- ["title", "summary"]}>
          <input
            type="text"
            placeholder={field}
            {collab_attrs(field, @collab_locks, @collab_client_id)}
          />
          <.field_indicator field={field} locks={@collab_locks} current_client_id={@collab_client_id} />
        </p>

        <h3>Cursors</h3>
        <.cursor_layer container_id="canvas" class="canvas">
          <p style="padding: 12px; color: #6b7280">Move your mouse here.</p>
        </.cursor_layer>
      </section>

      <aside>
        <h3>Diagnostics (LiveCollab.Telemetry)</h3>
        <table>
          <tr :for={d <- @diagnostics}>
            <td>{d.at}</td>
            <td><strong>{d.event}</strong><br />{d.details}</td>
          </tr>
        </table>
      </aside>
    </div>
    """
  end
end

defmodule Demo.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :fetch_session
    plug :protect_from_forgery
    plug :put_root_layout, html: {Demo.Layout, :root}
  end

  scope "/" do
    pipe_through :browser
    live "/", Demo.CollabLive
  end
end

defmodule Demo.Endpoint do
  use Phoenix.Endpoint, otp_app: :live_collab

  @session [store: :cookie, key: "_demo", signing_salt: "demo_session"]

  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session]]

  plug Plug.Static, at: "/assets/phoenix", from: {:phoenix, "priv/static"}
  plug Plug.Static, at: "/assets/phoenix_live_view", from: {:phoenix_live_view, "priv/static"}
  plug Plug.Static, at: "/assets/live_collab", from: Path.expand("../assets/js/live_collab", __DIR__)
  plug Plug.Session, @session
  plug Demo.Router
end

Demo.Diagnostics.attach()
LiveCollab.Telemetry.attach_default_logger()

{:ok, _} =
  Supervisor.start_link(
    [{Phoenix.PubSub, name: Demo.PubSub}, Demo.Presence, Demo.Endpoint],
    strategy: :one_for_one
  )

IO.puts("LiveCollab demo running at http://localhost:#{System.get_env("PORT", "4000")}/?name=Alice")
Process.sleep(:infinity)
