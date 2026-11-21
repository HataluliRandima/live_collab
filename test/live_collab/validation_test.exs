defmodule LiveCollab.ValidationTest do
  use ExUnit.Case, async: true
  alias LiveCollab.Validation

  describe "identifier/2" do
    test "accepts DOM-style identifiers" do
      for id <- ["board", "row:42", "items[3].name", "a/b-c_d.e"] do
        assert {:ok, ^id} = Validation.identifier(id, 255)
      end
    end

    test "rejects markup, traversal, control characters, unicode and oversize" do
      assert {:error, :disallowed_characters} = Validation.identifier("<b>", 255)
      assert {:error, :disallowed_characters} = Validation.identifier("a..b", 255)
      assert {:error, :disallowed_characters} = Validation.identifier("a\nb", 255)
      assert {:error, :disallowed_characters} = Validation.identifier("café", 255)
      assert {:error, :disallowed_characters} = Validation.identifier("a b", 255)
      assert {:error, :too_long} = Validation.identifier("abcd", 3)
      assert {:error, :empty} = Validation.identifier("", 255)
      assert {:error, :invalid_encoding} = Validation.identifier(<<0xFF, 0xFE>>, 255)
      assert {:error, :invalid_type} = Validation.identifier(:atom, 255)
    end

    test "optional_identifier/2 treats nil as absent" do
      assert {:ok, nil} = Validation.optional_identifier(nil, 10)
      assert {:error, :invalid_type} = Validation.optional_identifier(1, 10)
    end
  end

  describe "number/1" do
    test "parses integers, floats and short numeric strings" do
      assert {:ok, 1.0} = Validation.number(1)
      assert {:ok, 0.25} = Validation.number(0.25)
      assert {:ok, 0.5} = Validation.number("0.5")
    end

    test "rejects huge integers, long strings and other types" do
      assert {:error, :number_out_of_range} = Validation.number(10 ** 400)
      assert {:error, :invalid_number_format} = Validation.number(String.duplicate("9", 33))
      assert {:error, :invalid_number_format} = Validation.number("1e")
      assert {:error, :invalid_number_type} = Validation.number(nil)
      assert {:error, :invalid_number_type} = Validation.number([1])
    end
  end

  describe "color/1" do
    test "accepts #rgb and #rrggbb, normalizing to #rrggbb" do
      assert {:ok, "#ff0000"} = Validation.color("#f00")
      assert {:ok, "#A1B2C3"} = Validation.color("#A1B2C3")
    end

    test "rejects anything that could inject CSS" do
      for bad <- [
            "red",
            "#ff0000; background: url(x)",
            "#ff00001a",
            "rgb(0,0,0)",
            "#gggggg",
            "",
            nil,
            123
          ] do
        assert {:error, :invalid_color} = Validation.color(bad)
      end
    end
  end

  describe "avatar_url/1" do
    test "allows http(s), root-relative and data:image URLs" do
      for url <- [
            "https://cdn.example/a.png",
            "http://x/a",
            "/avatars/1.png",
            "data:image/png;base64,AAA"
          ] do
        assert {:ok, ^url} = Validation.avatar_url(url)
      end
    end

    test "rejects script schemes and protocol-relative URLs" do
      for bad <- [
            "javascript:alert(1)",
            "JaVaScRiPt:alert(1)",
            "//evil.example/x",
            "data:text/html,x",
            1
          ] do
        assert {:error, :invalid_avatar_url} = Validation.avatar_url(bad)
      end
    end
  end
end
