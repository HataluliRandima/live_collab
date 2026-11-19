defmodule LiveCollab.Field do
  @moduledoc """
  Manages field-level locks, deterministic conflict resolution, sanitization,
  and server-side changeset validations.

  ## Deterministic Conflict Resolution (Tie-Breaking)

  Because `Phoenix.Presence` is eventually consistent (CRDT), concurrent focus events
  from two users during network partition or identical millisecond windows will result
  in both clients initially claiming the lock in their local presence metadata.

  `LiveCollab.Field` resolves this deterministically across all nodes without a central
  lock coordinator by sorting claims on:

      `{acquired_at, client_id}`

  1. The claim with the earliest `acquired_at` timestamp wins.
  2. If timestamps are identical, the lexicographically lower `client_id` wins.

  Because all nodes have identical inputs and identical deterministic comparison rules,
  every node arrives at the identical winner simultaneously upon CRDT state merge.
  """

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

  def validate_field_id(field_id, max_length) when is_binary(field_id) do
    cond do
      byte_size(field_id) == 0 ->
        {:error, :empty_field_id}

      byte_size(field_id) > max_length ->
        {:error, :field_id_too_long}

      not String.valid?(field_id) ->
        {:error, :invalid_encoding}

      String.contains?(field_id, "..") ->
        {:error, :disallowed_characters}

      Regex.match?(~r/^[a-zA-Z0-9_\.\-:\[\]]+$/, field_id) ->
        {:ok, field_id}

      true ->
        {:error, :disallowed_characters}
    end
  end

  def validate_field_id(_invalid, _max_length), do: {:error, :invalid_type}

  @doc """
  Resolves a list of competing field claims into a deterministic winner.

  Uses `{time_bucket, client_id, user_id}` ordering:
  - Bins timestamps into `clock_skew_tolerance_ms` windows (default 500ms).
  - Claims acquired earlier outside the tolerance window win decisively.
  - Claims acquired within the same tolerance window are treated as concurrent,
    breaking ties deterministically by `client_id` (and `user_id` as secondary)
    without vulnerability to inter-node clock skew.
  - Future timestamp drift and invalid timestamps are safely bounded.
  """
  @spec resolve_conflict([lock_meta()], non_neg_integer()) :: lock_meta() | nil
  def resolve_conflict(claims, clock_skew_tolerance_ms \\ 500)
  def resolve_conflict([], _tolerance), do: nil
  def resolve_conflict([single], _tolerance), do: single

  def resolve_conflict(claims, clock_skew_tolerance_ms) when is_list(claims) do
    now = System.system_time(:millisecond)

    Enum.min_by(claims, fn claim ->
      acquired_at = Map.get(claim, :acquired_at, :infinity)

      sanitized_at =
        cond do
          not is_integer(acquired_at) or acquired_at <= 0 ->
            :infinity

          is_integer(acquired_at) and acquired_at > now + clock_skew_tolerance_ms ->
            now + clock_skew_tolerance_ms

          true ->
            acquired_at
        end

      time_key =
        if is_integer(sanitized_at) and clock_skew_tolerance_ms > 0 do
          div(sanitized_at, clock_skew_tolerance_ms)
        else
          sanitized_at
        end

      {
        time_key,
        to_string(Map.get(claim, :client_id, "")),
        to_string(Map.get(claim, :user_id, ""))
      }
    end)
  end

  @doc """
  Given a list of presence entries from `Phoenix.Presence.list/1`, extracts all
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

  defp apply_changeset_error(changeset, field, message) do
    if Code.ensure_loaded?(Ecto.Changeset) do
      apply(Ecto.Changeset, :add_error, [changeset, field, message])
    else
      errors = Map.get(changeset, :errors, [])
      Map.put(changeset, :errors, [{field, {message, []}} | errors])
    end
  end

  defp normalize_atom(val) when is_atom(val), do: val
  defp normalize_atom(val) when is_binary(val) do
    try do
      String.to_existing_atom(val)
    rescue
      ArgumentError -> String.to_atom(val)
    end
  end
end
