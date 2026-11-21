defmodule LiveCollab.Test.Presence do
  @moduledoc false
  # A real Phoenix.Presence (backed by Phoenix.Tracker). Integration tests must run
  # against the genuine API: a hand-written mock previously accepted a LiveView
  # socket where the real Tracker only accepts a pid, which hid a crash in `track/4`.
  use Phoenix.Presence, otp_app: :live_collab, pubsub_server: LiveCollab.Test.PubSub
end

defmodule LiveCollab.Test.ErrorHTML do
  @moduledoc false
  def render(template, _assigns), do: Phoenix.Controller.status_message_from_template(template)
end

defmodule LiveCollab.Test.CollabLive do
  @moduledoc false
  # Minimal LiveView mirroring the documented integration: `LiveCollab.track/4` in mount.
  #
  # Session keys:
  #   "user" - the user map passed to `LiveCollab.track/4`
  #   "opts" - keyword overrides passed to `LiveCollab.track/4`
  #   "assigns" - extra assigns applied before tracking (e.g. `collab_can_present?`)
  use Phoenix.LiveView

  @impl true
  def mount(%{"id" => id}, session, socket) do
    user = Map.get(session, "user", %{id: "anonymous", name: "Anonymous"})

    opts =
      Keyword.merge(
        [presence: LiveCollab.Test.Presence, pubsub: LiveCollab.Test.PubSub],
        Map.get(session, "opts", [])
      )

    extra = Map.get(session, "assigns", %{})

    socket =
      socket
      |> assign(extra)
      |> assign(:user, user)
      |> assign(:opts, opts)
      |> assign(:app_events, [])
      |> LiveCollab.track("doc:#{id}", user, opts)

    {:ok, socket}
  end

  @impl true
  def handle_event("retrack", %{"id" => id}, socket) do
    {:noreply, LiveCollab.track(socket, "doc:#{id}", socket.assigns.user, socket.assigns.opts)}
  end

  def handle_event("untrack", _params, socket) do
    {:noreply, LiveCollab.untrack(socket)}
  end

  # Simulates an app that persisted values and announces them to collaborators.
  def handle_event("save", %{"changes" => changes}, socket) do
    {:noreply, LiveCollab.broadcast_changes(socket, changes)}
  end

  # Application events must keep flowing through LiveCollab's hooks untouched.
  def handle_event("app_event", params, socket) do
    {:noreply, update(socket, :app_events, &[params | &1])}
  end

  @impl true
  def handle_info({:live_collab, :remote_changes, info}, socket) do
    {:noreply, update(socket, :app_events, &[{:remote_changes, info} | &1])}
  end

  def handle_info({:app_message, msg}, socket) do
    {:noreply, update(socket, :app_events, &[{:info, msg} | &1])}
  end

  @impl true
  def render(assigns) do
    # Counts renders so tests can prove that high-frequency events do not
    # trigger re-renders (read with LiveCollab.CollabCase.render_count/1).
    Process.put(:live_collab_test_renders, Process.get(:live_collab_test_renders, 0) + 1)

    ~H"""
    <div id="collab">
      <%!-- Every LiveCollab hook helper, so tests can check the rendered markup. --%>
      <input type="text" name="title" {LiveCollab.Components.collab_attrs("doc.title", @collab_locks, @collab_client_id)} />
      <table>
        <tr {LiveCollab.Components.collab_row_attrs("row:1", @collab_activities, @collab_client_id)}>
          <td>row</td>
        </tr>
      </table>
      <LiveCollab.Components.cursor_layer container_id="canvas">c</LiveCollab.Components.cursor_layer>
      <LiveCollab.Components.viewport_container container_id="doc">v</LiveCollab.Components.viewport_container>
      <LiveCollab.Components.selection_layer container_id="board">s</LiveCollab.Components.selection_layer>
      <LiveCollab.Components.status_reporter />
      <span id="users-count">{length(@collab_users)}</span>
      <span :for={{field, lock} <- @collab_locks} id={"lock-#{field}"}>{lock.user_name}</span>
    </div>
    """
  end
end

defmodule LiveCollab.Test.Router do
  @moduledoc false
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :fetch_session
  end

  scope "/" do
    pipe_through :browser
    live "/doc/:id", LiveCollab.Test.CollabLive
  end
end

defmodule LiveCollab.Test.Endpoint do
  @moduledoc false
  use Phoenix.Endpoint, otp_app: :live_collab

  @session_options [
    store: :cookie,
    key: "_live_collab_test",
    signing_salt: "lc_test_signing",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]]

  plug Plug.Session, @session_options
  plug LiveCollab.Test.Router
end
