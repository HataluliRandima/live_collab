defmodule LiveCollab.Field do
  @moduledoc """
  Manages field-level locks, deterministic conflict resolution, sanitization,
  and server-side changeset validations.

  ## Advisory locks and conflict resolution

  Field locks are **advisory**: they are claims stored in each collaborator's
  `Phoenix.Presence` metadata, not a mutual-exclusion primitive. Presence is an
  eventually consistent CRDT, so two clients (possibly on different nodes, or on
  both sides of a network partition) can claim the same field concurrently.

  Every node resolves competing claims with the same pure function,
  `resolve_conflict/2`, over the same converged Presence state, so **all nodes
  agree on the winner once Presence has converged**. Clients that lose are sent
  `live_collab:lock_lost`. Before convergence (e.g. during a partition) each side
  may briefly believe it holds the lock — use `validate_not_locked/5` on submit,
  and treat locks as a UX aid rather than a data-integrity guarantee.

  Claim timestamps are taken from the wall clock of the node hosting each
  LiveView. With clock skew larger than `clock_skew_tolerance_ms` between nodes,
  "earliest claim wins" reflects the skewed clocks rather than real time; the
  outcome is still deterministic and identical on every node.
  """

  # Ecto is optional: LiveCollab compiles and runs without it.
  @compile {:no_warn_undefined, Ecto.Changeset}

  @field_id_regex ~r/\A[a-zA-Z0-9_\.\-:\[\]]+\z/

  @type client_id :: String.t()
  @type user_id :: String.t() | integer()

  @type lock_meta :: %{
          required(:client_id) => client_id(),
          required(:user_id) => user_id(),
          required(:user_name) => String.t(),
          optional(:user_avatar) => String.t() | nil,
          optional(:user_color) => String.t(),
          required(:acquired_at) => integer(),
          required(:field) => String.t()
        }

  @type locks_map :: %{optional(String.t()) => lock_meta()}

  @doc """
  Sanitizes and validates a field identifier sent from an untrusted client.

  Returns `{:ok, sanitized_field_id}` or `{:error, reason}`.

  Field identifiers must:
  - Be valid UTF-8 strings
  - Not exceed max length (default 255 bytes)
  - Contain only alphanumeric characters, dots, underscores, dashes, and colons
  """
  @spec validate_field_id(term(), pos_integer()) :: {:ok, String.t()} | {:error, atom()}
  def validate_field_id(field_id, max_length \\ 255)

  def validate_field_id(field_id, max_length) do
    case LiveCollab.Validation.identifier(field_id, max_length, @field_id_regex) do
      {:ok, id} -> {:ok, id}
      {:error, :empty} -> {:error, :empty_field_id}
      {:error, :too_long} -> {:error, :field_id_too_long}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Resolves competing claims on one field into a single, deterministic winner.

  Claims are ordered by `{window, client_id, user_id}` where
  `window = div(acquired_at, clock_skew_tolerance_ms)`:

    * a claim in an earlier time window wins;
    * claims in the same window are ordered by `client_id` (then `user_id`);
    * claims with a missing or non-positive `acquired_at` sort last.

  The function is pure — it depends only on its arguments, never on the local
  clock — so every node computes the same winner from the same set of claims,
  regardless of the order in which they arrived.

  Windows are fixed-size buckets, so two claims a few milliseconds apart can
  straddle a window boundary; in that case the earlier one wins on time. A
  `clock_skew_tolerance_ms` of `0` orders strictly by timestamp.
  """
  @spec resolve_conflict([map()], non_neg_integer()) :: map() | nil
  def resolve_conflict(claims, clock_skew_tolerance_ms \\ 500)
  def resolve_conflict([], _tolerance), do: nil
  def resolve_conflict([single], _tolerance), do: single

  def resolve_conflict(claims, clock_skew_tolerance_ms)
      when is_list(claims) and is_integer(clock_skew_tolerance_ms) and
             clock_skew_tolerance_ms >= 0 do
    Enum.min_by(claims, &claim_sort_key(&1, clock_skew_tolerance_ms))
  end

  defp claim_sort_key(claim, tolerance) do
    time_key =
      case Map.get(claim, :acquired_at) do
        at when is_integer(at) and at > 0 and tolerance > 0 -> div(at, tolerance)
        at when is_integer(at) and at > 0 -> at
        # Atoms sort after all integers in Erlang term order.
        _invalid -> :infinity
      end

    {time_key, to_string(Map.get(claim, :client_id, "")), to_string(Map.get(claim, :user_id, ""))}
  end

  @doc """
  Given a list of presence entries from `c:Phoenix.Presence.list/1`, extracts all
  active field locks and deterministically resolves any conflicting claims.

  Returns a map of `%{field_id => lock_meta}`.
  """
  @spec extract_locks(map(), keyword()) :: locks_map()
  def extract_locks(presence_entries, opts \\ []) when is_map(presence_entries) do
    tolerance = Keyword.get(opts, :clock_skew_tolerance_ms, 500)

    claims_by_field =
      for {_key, %{metas: metas}} <- presence_entries,
          meta <- metas,
          field = Map.get(meta, :field),
          is_binary(field) and field != "" do
        {field, meta}
      end
      |> Enum.group_by(fn {field, _meta} -> field end, fn {_field, meta} -> meta end)

    claims_by_field
    |> Enum.map(fn {field, claims} -> {field, resolve_conflict(claims, tolerance)} end)
    |> Enum.into(%{})
  end

  @doc """
  Checks if a field is currently locked by a client other than `current_client_id`.
  """
  @spec locked_by_other?(locks_map(), String.t(), client_id() | nil) :: boolean()
  def locked_by_other?(locks, field_id, current_client_id) when is_map(locks) do
    case Map.get(locks, field_id) do
      nil -> false
      %{client_id: ^current_client_id} -> false
      _other_lock -> true
    end
  end

  @doc """
  Checks if a field is locked by any client.
  """
  @spec locked?(locks_map(), String.t()) :: boolean()
  def locked?(locks, field_id) when is_map(locks) do
    Map.has_key?(locks, field_id)
  end

  @doc """
  Returns the user/meta currently locking a field, or `nil` if free.
  """
  @spec current_holder(locks_map(), String.t()) :: lock_meta() | nil
  def current_holder(locks, field_id) when is_map(locks) do
    Map.get(locks, field_id)
  end

  @doc """
  Ecto changeset validation helper. Rejects changes to fields that are currently
  locked by another collaborative user during `phx-change` or `phx-submit`.

  ## Example

      def validate_or_save(socket, params) do
        %Order{}
        |> Order.changeset(params)
        |> LiveCollab.Field.validate_not_locked(:customer_name, socket.assigns.collab_locks, socket.assigns.collab_client_id)
      end
  """
  @spec validate_not_locked(
          changeset :: term(),
          field_name :: atom() | String.t(),
          locks :: locks_map(),
          client_id :: client_id() | nil,
          opts :: keyword()
        ) :: term()
  def validate_not_locked(changeset, field_name, locks, client_id, opts \\ []) do
    field_str = to_string(field_name)

    if locked_by_other?(locks, field_str, client_id) do
      holder = current_holder(locks, field_str)
      holder_name = holder[:user_name] || "another user"
      message = Keyword.get(opts, :message, "is currently being edited by #{holder_name}")

      # Dynamically invoke Ecto.Changeset.add_error/4 if Ecto is loaded,
      # otherwise add to errors keyword list defensively
      apply_changeset_error(changeset, normalize_atom(field_name), message)
    else
      changeset
    end
  end

  # Ecto is optional, so dialyzer cannot see Ecto.Changeset in the PLT.
  @dialyzer {:nowarn_function, apply_changeset_error: 3}
  defp apply_changeset_error(changeset, field, message) do
    if is_struct(changeset, Ecto.Changeset) and Code.ensure_loaded?(Ecto.Changeset) do
      Ecto.Changeset.add_error(changeset, field, message)
    else
      errors = Map.get(changeset, :errors, [])
      Map.put(changeset, :errors, [{field, {message, []}} | errors])
    end
  end

  defp normalize_atom(val) when is_atom(val), do: val
  # Never create atoms from strings: atoms are not garbage collected, so
  # `String.to_atom/1` on caller-provided names can exhaust the atom table.
  # A field name that is not an existing atom cannot be a schema field anyway;
  # Ecto.Changeset.add_error/3 accepts the string key unchanged.
  defp normalize_atom(val) when is_binary(val) do
    String.to_existing_atom(val)
  rescue
    ArgumentError -> val
  end
end
