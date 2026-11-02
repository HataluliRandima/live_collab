defmodule LiveCollab.Element do
  @moduledoc """
  Manages element and table-row activity indicators.

  Unlike field locks—which are exclusive/advisory single-user leases—element
  activity represents **shared multi-user presence**: multiple collaborators
  can simultaneously view, select, or edit within the same table row, kanban card,
  or document section.

  ## Activity Types

  - `:viewing` - The user has focused, clicked, or hovered (with intent) on the element.
  - `:selected` - The user has explicitly selected the element (e.g., row checkbox).
  - `:editing` - The user is actively editing a field located inside this element.
  """

  alias LiveCollab.Presence

  @type activity_type :: :viewing | :selected | :editing

  @type element_activity :: %{
          required(:client_id) => String.t(),
          required(:user_id) => String.t() | integer(),
          required(:user_name) => String.t(),
          optional(:user_avatar) => String.t() | nil,
          required(:user_color) => String.t(),
          required(:type) => activity_type(),
          optional(:field) => String.t() | nil,
          required(:acquired_at) => integer()
        }

  @type activities_map :: %{optional(String.t()) => [element_activity()]}

  @doc """
  Sanitizes and validates an element identifier sent from an untrusted client.

  Returns `{:ok, sanitized_element_id}` or `{:error, reason}`.

  Element identifiers must:
  - Be valid UTF-8 strings
  - Not exceed max length (default 255 bytes)
  - Contain only alphanumeric characters, dots, underscores, dashes, colons, slashes, or brackets.
  """
  @spec validate_element_id(term(), pos_integer()) :: {:ok, String.t()} | {:error, atom()}
  def validate_element_id(element_id, max_length \\ 255)

  def validate_element_id(element_id, max_length) when is_binary(element_id) do
    cond do
      byte_size(element_id) == 0 ->
        {:error, :empty_element_id}

      byte_size(element_id) > max_length ->
        {:error, :element_id_too_long}

      not String.valid?(element_id) ->
        {:error, :invalid_encoding}

      String.contains?(element_id, "..") ->
        {:error, :disallowed_characters}

      Regex.match?(~r/^[a-zA-Z0-9_\.\-:\/\[\]]+$/, element_id) ->
        {:ok, element_id}

      true ->
        {:error, :disallowed_characters}
    end
  end

  def validate_element_id(_invalid, _max_length), do: {:error, :invalid_type}

  @doc """
  Normalizes an activity type atom or string into one of `:viewing`, `:selected`, or `:editing`.
  Defaults to `:viewing`.
  """
  @spec normalize_activity_type(term()) :: activity_type()
  def normalize_activity_type(:editing), do: :editing
  def normalize_activity_type(:selected), do: :selected
  def normalize_activity_type(:viewing), do: :viewing
  def normalize_activity_type("editing"), do: :editing
  def normalize_activity_type("selected"), do: :selected
  def normalize_activity_type("viewing"), do: :viewing
  def normalize_activity_type(_other), do: :viewing

  @doc """
  Given raw presence entries from `Phoenix.Presence.list/1`, extracts all active
  element activities, grouping collaborators by element ID.

  Consolidates multi-tab sessions for the same user while preserving the highest
  precedence activity (`:editing` > `:selected` > `:viewing`).
  """
  @spec extract_activities(map(), keyword()) :: activities_map()
  def extract_activities(presence_entries, opts \\ []) when is_map(presence_entries) do
    dedup_users = Keyword.get(opts, :dedup_users, true)

    raw_activities =
      for {_user_key, %{metas: metas}} <- presence_entries,
          meta <- metas,
          element = Map.get(meta, :element),
          is_binary(element) and element != "" do
        type =
          cond do
            # If the user is currently editing a field inside this element, upgrade to :editing
            meta[:field] && meta[:field] != "" -> :editing
            meta[:element_type] -> normalize_activity_type(meta[:element_type])
            true -> :viewing
          end

        activity = %{
          client_id: Map.get(meta, :client_id, ""),
          user_id: Map.get(meta, :user_id, ""),
          user_name: Map.get(meta, :user_name, "User"),
          user_avatar: Map.get(meta, :user_avatar),
          user_color:
            Map.get(meta, :user_color) || Presence.deterministic_color(meta[:user_id]),
          type: type,
          field: Map.get(meta, :field),
          acquired_at: Map.get(meta, :element_acquired_at, 0)
        }

        {element, activity}
      end

    grouped =
      raw_activities
      |> Enum.group_by(fn {element, _activity} -> element end, fn {_element, activity} ->
        activity
      end)

    if dedup_users do
      Enum.into(grouped, %{}, fn {element, activities} ->
        consolidated =
          activities
          |> Enum.group_by(& &1.user_id)
          |> Enum.map(fn {_uid, user_activities} ->
            # Pick highest precedence activity for this user on this element
            Enum.max_by(user_activities, &activity_precedence(&1.type))
          end)
          |> Enum.sort_by(&{&1.type != :editing, &1.acquired_at})

        {element, consolidated}
      end)
    else
      Enum.into(grouped, %{}, fn {element, activities} ->
        sorted = Enum.sort_by(activities, &{&1.type != :editing, &1.acquired_at})
        {element, sorted}
      end)
    end
  end

  @doc """
  Returns all collaborators active on a given element.
  """
  @spec active_users(activities_map(), String.t()) :: [element_activity()]
  def active_users(activities, element_id) when is_map(activities) do
    Map.get(activities, element_id, [])
  end

  @doc """
  Checks if any other collaborator (excluding `current_client_id`) is active on the element.
  """
  @spec active_by_other?(activities_map(), String.t(), String.t() | nil) :: boolean()
  def active_by_other?(activities, element_id, current_client_id) when is_map(activities) do
    case Map.get(activities, element_id) do
      nil ->
        false

      users ->
        Enum.any?(users, fn user ->
          user.client_id != current_client_id
        end)
    end
  end

  @doc """
  Returns true if any collaborator is currently editing inside this element.
  """
  @spec editing?(activities_map(), String.t()) :: boolean()
  def editing?(activities, element_id) when is_map(activities) do
    case Map.get(activities, element_id) do
      nil -> false
      users -> Enum.any?(users, &(&1.type == :editing))
    end
  end

  # Precedence: :editing (3) > :selected (2) > :viewing (1)
  defp activity_precedence(:editing), do: 3
  defp activity_precedence(:selected), do: 2
  defp activity_precedence(:viewing), do: 1
  defp activity_precedence(_), do: 0
end

