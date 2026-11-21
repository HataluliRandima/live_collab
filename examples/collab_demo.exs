# LiveCollab demo: presence, field locks, cursors and a live telemetry panel.
#
#     elixir examples/collab_demo.exs
#
# Then open http://localhost:4000/?name=Alice and http://localhost:4000/?name=Bob
# in two windows and try each section:
#
#   * Avatars dim when someone switches tabs or is idle for 15 seconds.
#   * Field locks: focus the same input in both windows. The other person can
#     press "Ask to edit"; the holder gets "Hand over" / "Keep editing".
#   * Conflicts: Alice types in Summary, clicks elsewhere, Bob starts editing
#     Summary, then Alice presses Save. Bob sees "Alice saved … while you were
#     editing" with "Use theirs" / "Keep mine". Fields nobody is editing just update.
#   * Rows: click a task (or hover for a moment) to show who is looking at it.
#   * Presenter: press "Present" and scroll the document; the other window follows.
#     Open ?name=Eve&role=viewer to see an unauthorized attempt rejected.
#   * Selections: drag a box over the cards.
#   * Cursors: move the mouse over the canvas (fast, to see rate limiting).
#
# The "Diagnostics" panel is fed by LiveCollab.Telemetry events.
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

defmodule Demo.Doc do
  @moduledoc "The demo's \"database\": one shared document held in an Agent."
  use Agent

  def start_link(_), do: Agent.start_link(fn -> %{"title" => "Q3 planning", "summary" => ""} end, name: __MODULE__)
  def get, do: Agent.get(__MODULE__, & &1)
  def put(changes), do: Agent.update(__MODULE__, &Map.merge(&1, changes))
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
  defp details([:status, :changed], _m, meta), do: to_string(meta.status)
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
          .diag { width: 100%; border-collapse: collapse; font: 12px ui-monospace, monospace; }
          .diag td { padding: 2px 4px; border-bottom: 1px solid #f3f4f6; vertical-align: top; }
          .hint { color: #6b7280; font-size: 12px; margin: 4px 0 8px; }
          /* handoff + conflicts */
          .field { margin-bottom: 10px; }
          .live-collab-field-indicator button { margin-left: 6px; padding: 0 6px; font-size: 11px; border: 0;
            border-radius: 4px; background: rgba(255,255,255,.25); color: #fff; cursor: pointer; }
          .notice { display: inline-flex; gap: 8px; align-items: center; margin: 4px 0; padding: 4px 8px;
            border-radius: 6px; background: #fff7ed; border: 1px solid #fdba74; font-size: 12px; }
          .notice span:first-child { width: 8px; height: 8px; border-radius: 999px; display: inline-block; }
          .collab-remote-updated { background: #fef9c3; transition: background .3s; }
          .collab-conflict { border-color: #f97316 !important; box-shadow: 0 0 0 2px #fed7aa; }
          /* away status */
          .live-collab-away { opacity: .35; filter: grayscale(1); }
          /* row activity */
          .rows { border-collapse: collapse; width: 100%; }
          .rows td { padding: 6px 8px; border-bottom: 1px solid #e5e7eb; }
          .rows tr { cursor: pointer; border-left: 4px solid transparent; }
          .rows tr[data-collab-active="true"] { border-left-color: var(--collab-element-color); background: #f9fafb; }
          .live-collab-row-indicator { display: inline-flex; align-items: center; gap: 4px; }
          .live-collab-row-indicator div[style] { width: 20px; height: 20px; border-radius: 999px; color: #fff;
            font-size: 10px; display: inline-flex; align-items: center; justify-content: center; }
          .live-collab-row-indicator > span { font-size: 10px; background: #fef3c7; color: #92400e; padding: 1px 4px; border-radius: 4px; }
          /* presenter */
          button { padding: 4px 10px; border-radius: 6px; border: 1px solid #d1d5db; background: #fff; cursor: pointer; }
          .doc { height: 200px; overflow-y: auto; border: 1px solid #e5e7eb; border-radius: 8px; padding: 0 16px; margin-top: 8px; }
          .live-collab-follow-pill { display: inline-flex; gap: 8px; align-items: center; margin-left: 8px; }
          /* selections */
          .board { position: relative; height: 180px; border: 1px dashed #9ca3af; border-radius: 8px;
            display: grid; grid-template-columns: repeat(4, 1fr); gap: 12px; padding: 16px; user-select: none; touch-action: none; }
          .card { background: #f3f4f6; border-radius: 6px; display: flex; align-items: center; justify-content: center; }
          .card.picked { outline: 2px solid #4F46E5; }
          .local-marquee { position: absolute; border: 1px dashed #4F46E5; background: rgba(79,70,229,.08); pointer-events: none; }
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
        <script type="module">
          // Demo-only: drag a marquee over the cards and report it through
          // LiveCollab's documented `live_collab:local_selection` DOM event.
          let drag = null;
          const clamp = (v) => Math.min(Math.max(v, 0), 1);

          const marqueeFor = (board) => {
            const holder = board.querySelector("[data-local-marquee]");
            let box = holder.firstElementChild;
            if (!box) { box = document.createElement("div"); box.className = "local-marquee"; holder.appendChild(box); }
            return box;
          };

          document.addEventListener("pointerdown", (e) => {
            const board = e.target.closest(".live-collab-selection-container");
            if (!board) return;
            const r = board.getBoundingClientRect();
            drag = { board, r, x0: clamp((e.clientX - r.left) / r.width), y0: clamp((e.clientY - r.top) / r.height), moved: false };
          });

          document.addEventListener("pointermove", (e) => {
            if (!drag) return;
            const { board, r, x0, y0 } = drag;
            const x1 = clamp((e.clientX - r.left) / r.width), y1 = clamp((e.clientY - r.top) / r.height);
            const sel = { x: Math.min(x0, x1), y: Math.min(y0, y1), width: Math.abs(x1 - x0), height: Math.abs(y1 - y0) };
            if (sel.width + sel.height < 0.01) return;
            drag.moved = true;

            const px = { left: r.left + sel.x * r.width, top: r.top + sel.y * r.height,
                         right: r.left + (sel.x + sel.width) * r.width, bottom: r.top + (sel.y + sel.height) * r.height };
            sel.selected_ids = [];
            board.querySelectorAll("[data-card]").forEach((card) => {
              const c = card.getBoundingClientRect();
              const hit = c.left < px.right && c.right > px.left && c.top < px.bottom && c.bottom > px.top;
              card.classList.toggle("picked", hit);
              if (hit) sel.selected_ids.push(card.id);
            });

            const box = marqueeFor(board);
            Object.assign(box.style, { display: "block", left: `${sel.x * 100}%`, top: `${sel.y * 100}%`,
                                       width: `${sel.width * 100}%`, height: `${sel.height * 100}%` });
            board.dispatchEvent(new CustomEvent("live_collab:local_selection", { bubbles: true, detail: sel }));
          });

          document.addEventListener("pointerup", () => {
            if (drag && !drag.moved) {
              drag.board.querySelectorAll("[data-card]").forEach((c) => c.classList.remove("picked"));
              marqueeFor(drag.board).style.display = "none";
              drag.board.dispatchEvent(new CustomEvent("live_collab:local_selection_clear", { bubbles: true }));
            }
            drag = null;
          });
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
      |> assign(:tasks, [{1, "Write release notes"}, {2, "Review pull request"}, {3, "Fix flaky test"}])
      |> assign(:doc, Demo.Doc.get())
      |> assign(:draft, Demo.Doc.get())
      |> assign(:saved_at, nil)
      # notify_changes: reload Demo.Doc when someone else saves.
      |> LiveCollab.track("demo:document", user, notify_changes: true)

    {:ok, socket}
  end

  @fields ["title", "summary"]

  @impl true
  def handle_event("validate", %{"doc" => params}, socket) do
    {:noreply, update(socket, :draft, &Map.merge(&1, Map.take(params, @fields)))}
  end

  # A naive save: persist every field whose value differs from the stored one,
  # then announce it. (A real app would also use LiveCollab.validate_not_locked/5.)
  def handle_event("save", %{"doc" => params}, socket) do
    stored = Demo.Doc.get()
    changes = for {field, value} <- Map.take(params, @fields), value != stored[field], into: %{}, do: {field, value}
    Demo.Doc.put(changes)

    {:noreply,
     socket
     |> assign(:doc, Demo.Doc.get())
     |> update(:draft, &Map.merge(&1, changes))
     |> assign(:saved_at, Time.utc_now() |> Time.truncate(:second))
     |> LiveCollab.broadcast_changes(changes)}
  end

  # Someone else saved: reload, but keep whatever is being typed in the field
  # this client is editing (that case gets a conflict notice instead).
  @impl true
  def handle_info({:live_collab, :remote_changes, %{changes: changes}}, socket) do
    doc = Demo.Doc.get()
    editing = socket.assigns.collab_editing_field
    taken = changes |> Map.keys() |> Enum.reject(&(&1 == editing))

    {:noreply,
     socket
     |> assign(:doc, doc)
     |> update(:draft, &Map.merge(&1, Map.take(doc, taken)))}
  end

  def handle_info({:diagnostic, entry}, socket) do
    {:noreply, update(socket, :diagnostics, &Enum.take([entry | &1], 25))}
  end

  defp leader_name(users, client_id) do
    Enum.find_value(users, "Someone", fn user ->
      Enum.any?(user.metas, &(&1[:client_id] == client_id)) && user.name
    end)
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

        <.status_reporter idle_after={15_000} />
        <.avatar_stack users={@collab_users} max={6} />
        <p class="hint">Avatars dim when that person switches tabs or is idle for 15 s.</p>

        <h3>Advisory field locks, handoff and conflicts</h3>
        <p class="hint">
          Focus a field to lock it; others can press "Ask to edit". Save stores the document and
          updates everyone else's form.
        </p>
        <.lock_requests requests={@collab_lock_requests} class="notice" />
        <form phx-change="validate" phx-submit="save">
          <div :for={field <- ["title", "summary"]} class="field">
            <input
              type="text"
              name={"doc[#{field}]"}
              value={@draft[field]}
              placeholder={field}
              {collab_attrs(field, @collab_locks, @collab_client_id)}
            />
            <.field_indicator
              field={field}
              locks={@collab_locks}
              current_client_id={@collab_client_id}
              asks={@collab_lock_asks}
            />
            <div><.field_change_notice field={field} changes={@collab_remote_changes} class="notice" /></div>
          </div>
          <button type="submit">Save</button>
          <span :if={@saved_at} class="hint">Saved at {@saved_at} UTC</span>
        </form>

        <h3>Row activity</h3>
        <p class="hint">Click a task, or hover for 0.4 s, to show the others who is looking at it.</p>
        <table class="rows">
          <tr
            :for={{id, task} <- @tasks}
            {collab_row_attrs("task:#{id}", @collab_activities, @collab_client_id, hover_intent: 400)}
          >
            <td>{task}</td>
            <td style="text-align: right">
              <.row_indicator
                element={"task:#{id}"}
                activities={@collab_activities}
                current_client_id={@collab_client_id}
              />
            </td>
          </tr>
        </table>

        <h3>
          Presenter mode
          <%!-- These events are handled (and authorized) by LiveCollab itself. --%>
          <%= if @collab_spotlight_leader == @collab_client_id do %>
            <button phx-click="live_collab:spotlight_stop">Stop presenting</button>
          <% else %>
            <button phx-click="live_collab:spotlight_lead">Present</button>
          <% end %>
          <.follow_pill
            :if={@collab_spotlight_leader && @collab_spotlight_leader != @collab_client_id}
            leader_name={leader_name(@collab_users, @collab_spotlight_leader)}
            leader_client_id={@collab_spotlight_leader}
            container_id="doc"
          />
        </h3>
        <p class="hint">
          While someone presents, the others follow their scrolling. Scroll yourself to break out; press Follow to rejoin.
        </p>
        <.viewport_container
          container_id="doc"
          presenter={@collab_spotlight_leader == @collab_client_id}
          auto_follow
          class="doc"
        >
          <section :for={n <- 1..12}>
            <h4>Section {n}</h4>
            <p>
              Placeholder text for section {n}. The presenter's scroll position is sent as a fraction
              of the scrollable height, so it lines up on screens of any size.
            </p>
          </section>
        </.viewport_container>

        <h3>Shared selections</h3>
        <p class="hint">Drag a box over the cards; click empty space to clear.</p>
        <.selection_layer container_id="board" class="board">
          <div :for={n <- 1..8} id={"card-#{n}"} data-card class="card">Card {n}</div>
          <div
            id="local-marquee"
            phx-update="ignore"
            data-local-marquee
            style="position: absolute; inset: 0; pointer-events: none;"
          >
          </div>
        </.selection_layer>

        <h3>Cursors</h3>
        <.cursor_layer container_id="canvas" class="canvas">
          <p style="padding: 12px; color: #6b7280">Move your mouse here.</p>
        </.cursor_layer>
      </section>

      <aside>
        <h3>Diagnostics (LiveCollab.Telemetry)</h3>
        <table class="diag">
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
    [{Phoenix.PubSub, name: Demo.PubSub}, Demo.Presence, Demo.Doc, Demo.Endpoint],
    strategy: :one_for_one
  )

IO.puts("LiveCollab demo running at http://localhost:#{System.get_env("PORT", "4000")}/?name=Alice")
Process.sleep(:infinity)
