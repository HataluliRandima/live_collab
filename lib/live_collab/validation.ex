defmodule LiveCollab.Validation do
  @moduledoc false
  # Shared validation for values that originate from untrusted clients.
  #
  # Every function here is total: any term may be passed and the result is either
  # `{:ok, value}` or `{:error, reason_atom}`. Nothing raises on bad input.

  @identifier_regex ~r/\A[a-zA-Z0-9_\.\-:\/\[\]]+\z/

  # Colors run on every presence rebuild for every collaborator, so they are
  # matched with binary patterns rather than a regex.
  defguardp is_hex(c) when c in ?0..?9 or c in ?a..?f or c in ?A..?F

  @typedoc "Reason atoms returned by validators."
  @type reason :: atom()

  @doc """
  Validates a DOM-ish identifier (field, element, container, anchor ids).

  Allowed: ASCII letters, digits, `_ . - : / [ ]`, at most `max_length` bytes,
  no `..` sequences. Returns `{:ok, id}` or `{:error, reason}`.
  """
  @spec identifier(term(), pos_integer(), Regex.t()) :: {:ok, String.t()} | {:error, reason()}
  def identifier(value, max_length, regex \\ @identifier_regex)

  def identifier(value, max_length, regex) when is_binary(value) do
    cond do
      value == "" -> {:error, :empty}
      byte_size(value) > max_length -> {:error, :too_long}
      not String.valid?(value) -> {:error, :invalid_encoding}
      String.contains?(value, "..") -> {:error, :disallowed_characters}
      Regex.match?(regex, value) -> {:ok, value}
      true -> {:error, :disallowed_characters}
    end
  end

  def identifier(_value, _max_length, _regex), do: {:error, :invalid_type}

  @doc """
  Like `identifier/2`, but `nil` (absent) is accepted and returned as `{:ok, nil}`.
  """
  @spec optional_identifier(term(), pos_integer()) :: {:ok, String.t() | nil} | {:error, reason()}
  def optional_identifier(nil, _max_length), do: {:ok, nil}
  def optional_identifier(value, max_length), do: identifier(value, max_length)

  @doc """
  Parses a finite number from an integer, float or numeric string.

  JSON cannot encode NaN/Infinity, so floats arriving from Jason are always
  finite; the string branch is bounded so huge numeric strings cannot be used to
  burn CPU.
  """
  @spec number(term()) :: {:ok, float()} | {:error, reason()}
  def number(value) when is_float(value), do: {:ok, value}
  def number(value) when is_integer(value) and abs(value) <= 1.0e15, do: {:ok, value * 1.0}
  def number(value) when is_integer(value), do: {:error, :number_out_of_range}

  def number(value) when is_binary(value) and byte_size(value) <= 32 do
    case Float.parse(value) do
      {num, ""} -> {:ok, num}
      _ -> {:error, :invalid_number_format}
    end
  end

  def number(value) when is_binary(value), do: {:error, :invalid_number_format}
  def number(_value), do: {:error, :invalid_number_type}

  @doc """
  Normalises a CSS hex color (`#rgb` or `#rrggbb`) to `#rrggbb`.

  Anything else is rejected: colors are interpolated into `style` attributes on
  the server and into inline styles in the browser, so only a strict hex form is
  safe from CSS injection.
  """
  @spec color(term()) :: {:ok, String.t()} | {:error, reason()}
  def color(<<"#", r, g, b>>) when is_hex(r) and is_hex(g) and is_hex(b),
    do: {:ok, <<"#", r, r, g, g, b, b>>}

  def color(<<"#", a, b, c, d, e, f>> = hex)
      when is_hex(a) and is_hex(b) and is_hex(c) and is_hex(d) and is_hex(e) and is_hex(f),
      do: {:ok, hex}

  def color(_value), do: {:error, :invalid_color}

  @doc """
  Accepts avatar URLs with an `http(s)` scheme, a root-relative path or an inline
  `data:image/` URI. Everything else (e.g. `javascript:`) is rejected.
  """
  @spec avatar_url(term()) :: {:ok, String.t() | nil} | {:error, reason()}
  def avatar_url(nil), do: {:ok, nil}

  def avatar_url(value) when is_binary(value) and byte_size(value) <= 8_192 do
    lowered = String.downcase(value)

    cond do
      String.starts_with?(lowered, ["https://", "http://", "data:image/"]) -> {:ok, value}
      String.starts_with?(value, "/") and not String.starts_with?(value, "//") -> {:ok, value}
      true -> {:error, :invalid_avatar_url}
    end
  end

  def avatar_url(_value), do: {:error, :invalid_avatar_url}
end
