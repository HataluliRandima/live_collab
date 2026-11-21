defmodule LiveCollab.CollabCase do
  @moduledoc false
  # Shared helpers for LiveView integration tests running against a real
  # Phoenix.Presence / Phoenix.PubSub stack.
  use ExUnit.CaseTemplate

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias LiveCollab.Test.Presence

  @endpoint LiveCollab.Test.Endpoint

  using do
    quote do
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import LiveCollab.CollabCase

      @endpoint LiveCollab.Test.Endpoint
    end
  end

  @doc "Unique document id per test so concurrent tests never share a Presence topic."
  def unique_doc, do: "t#{System.unique_integer([:positive])}"

  @doc "Topic LiveCollab derives for `doc:<id>` with the default prefix."
  def topic_for(doc), do: "live_collab:doc:#{doc}"

  @doc "Mounts the integration LiveView as `user`. Returns the connected view."
  def join(doc, user, opts \\ []) do
    session = %{
      "user" => user,
      "opts" => Keyword.get(opts, :collab_opts, []),
      "assigns" => Keyword.get(opts, :assigns, %{})
    }

    conn = build_conn() |> Plug.Test.init_test_session(session)
    {:ok, view, _html} = live(conn, "/doc/#{doc}")
    view
  end

  @doc "Reads the server-side socket assigns of a LiveView under test."
  def assigns(view), do: socket(view).assigns

  @doc "Reads the server-side socket of a LiveView under test."
  def socket(view) do
    # Synchronises with the LiveView process: any message already in its mailbox
    # (e.g. a presence_diff) is processed before :sys.get_state/1 returns.
    %{socket: socket} = :sys.get_state(view.pid)
    socket
  end

  @doc """
  Polls `fun` until it returns a truthy value or `timeout` elapses.

  Presence diffs are delivered asynchronously by Phoenix.Presence, so assertions
  about other collaborators' state are eventually-consistent by design. Polling
  with a deadline is deterministic in outcome, unlike fixed sleeps.
  """
  def eventually(fun, timeout \\ 2_000, interval \\ 10) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, deadline, interval)
  end

  defp do_eventually(fun, deadline, interval) do
    case fun.() do
      falsy when falsy in [nil, false] ->
        if System.monotonic_time(:millisecond) > deadline do
          ExUnit.Assertions.flunk("condition not met before timeout")
        else
          Process.sleep(interval)
          do_eventually(fun, deadline, interval)
        end

      truthy ->
        truthy
    end
  end

  @doc "Number of times the LiveView under test has rendered."
  def render_count(view) do
    # :sys.get_state/1 first, so queued messages are processed before we look.
    _ = :sys.get_state(view.pid)
    {:dictionary, dict} = Process.info(view.pid, :dictionary)
    Keyword.get(dict, :live_collab_test_renders, 0)
  end

  @doc "Returns whether `view` pushed `event` within `timeout` ms (non-raising)."
  defmacro push_received?(view, event, timeout) do
    quote do
      try do
        Phoenix.LiveViewTest.assert_push_event(unquote(view), unquote(event), _, unquote(timeout))
        true
      rescue
        ExUnit.AssertionError -> false
      end
    end
  end

  @doc "Presence entries for a test document topic."
  def presence_list(doc), do: Presence.list(topic_for(doc))

  @doc """
  Forwards the given telemetry events emitted by the LiveView `view` (matched on
  its client id) to the test process. Handlers are global, so filtering keeps
  async tests from observing each other's events.
  """
  def capture_telemetry(view, events) do
    client_id = assigns(view).collab_client_id
    ref = make_ref()
    handler_id = {__MODULE__, ref}
    parent = self()

    :telemetry.attach_many(
      handler_id,
      events,
      fn event, measurements, metadata, _ ->
        if metadata[:client_id] == client_id do
          send(parent, {:telemetry, event, measurements, metadata})
        end
      end,
      nil
    )

    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(handler_id) end)
    ref
  end
end
