defmodule LiveCollab.ComponentsTest do
  use ExUnit.Case, async: true
  alias LiveCollab.Components

  describe "collab_attrs/4" do
    test "generates standard unlocked hook attributes" do
      locks = %{}
      attrs = Components.collab_attrs("customer.name", locks, "client_me")

      assert Keyword.get(attrs, :"phx-hook") == "LiveCollabField"
      assert Keyword.get(attrs, :"data-collab-field") == "customer.name"
      assert Keyword.get(attrs, :"data-collab-locked") == "false"
      assert Keyword.get(attrs, :"data-collab-locked-by-client") == ""
      refute Keyword.has_key?(attrs, :readonly)
      refute Keyword.has_key?(attrs, :"aria-readonly")
    end

    test "generates readonly attributes when locked by another client" do
      locks = %{
        "customer.name" => %{
          client_id: "client_other",
          user_name: "Bob",
          field: "customer.name"
        }
      }

      attrs = Components.collab_attrs("customer.name", locks, "client_me")

      assert Keyword.get(attrs, :"data-collab-locked") == "true"
      assert Keyword.get(attrs, :"data-collab-locked-by-client") == "client_other"
      assert Keyword.get(attrs, :readonly) == "readonly"
      assert Keyword.get(attrs, :"aria-readonly") == "true"
    end

    test "does not mark readonly if held by the current client" do
      locks = %{
        "customer.name" => %{
          client_id: "client_me",
          user_name: "Me",
          field: "customer.name"
        }
      }

      attrs = Components.collab_attrs("customer.name", locks, "client_me")

      assert Keyword.get(attrs, :"data-collab-locked") == "false"
      refute Keyword.has_key?(attrs, :readonly)
    end

    test "respects readonly: false option override" do
      locks = %{
        "customer.name" => %{
          client_id: "client_other",
          user_name: "Bob",
          field: "customer.name"
        }
      }

      attrs = Components.collab_attrs("customer.name", locks, "client_me", readonly: false)

      assert Keyword.get(attrs, :"data-collab-locked") == "true"
      refute Keyword.has_key?(attrs, :readonly)
    end
  end
end
