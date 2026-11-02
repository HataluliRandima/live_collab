defmodule LiveCollab.FieldTest do
  use ExUnit.Case, async: true
  alias LiveCollab.Field

  describe "validate_field_id/2" do
    test "accepts valid field strings" do
      assert {:ok, "customer.name"} = Field.validate_field_id("customer.name")
      assert {:ok, "order_item_123"} = Field.validate_field_id("order_item_123")
      assert {:ok, "form[user][email]"} = Field.validate_field_id("form[user][email]")
      assert {:ok, "user:profile:bio"} = Field.validate_field_id("user:profile:bio")
    end

    test "rejects empty field id" do
      assert {:error, :empty_field_id} = Field.validate_field_id("")
    end

    test "rejects excessively long field strings" do
      oversized = String.duplicate("a", 256)
      assert {:error, :field_id_too_long} = Field.validate_field_id(oversized, 255)
    end

    test "rejects script injection or invalid characters" do
      assert {:error, :disallowed_characters} =
               Field.validate_field_id("<script>alert(1)</script>")

      assert {:error, :disallowed_characters} = Field.validate_field_id("name; DROP TABLE orders")
      assert {:error, :disallowed_characters} = Field.validate_field_id("field with spaces")
    end

    test "rejects non-binary input" do
      assert {:error, :invalid_type} = Field.validate_field_id(123)
      assert {:error, :invalid_type} = Field.validate_field_id(nil)
      assert {:error, :invalid_type} = Field.validate_field_id(%{})
    end
  end

  describe "resolve_conflict/1 deterministic tie-breaking" do
    test "returns nil for empty list" do
      assert Field.resolve_conflict([]) == nil
    end

    test "returns single claim immediately" do
      claim = %{client_id: "c1", user_id: "u1", acquired_at: 1000, field: "name"}
      assert Field.resolve_conflict([claim]) == claim
    end

    test "earliest acquired_at timestamp outside tolerance window wins" do
      early = %{client_id: "c_bob", user_id: "u_bob", acquired_at: 1000, field: "name"}
      late = %{client_id: "c_alice", user_id: "u_alice", acquired_at: 6000, field: "name"}

      assert Field.resolve_conflict([early, late]) == early
      assert Field.resolve_conflict([late, early]) == early
    end

    test "claims within clock skew tolerance window are resolved deterministically by client_id" do
      # Two claims within 50ms of each other (within 500ms default tolerance window)
      skewed_early = %{client_id: "c_bob", user_id: "u_bob", acquired_at: 1000, field: "name"}
      skewed_late = %{client_id: "c_alice", user_id: "u_alice", acquired_at: 1050, field: "name"}

      # Because "c_alice" < "c_bob", client_id tie-breaking breaks the tie without clock skew bias
      assert Field.resolve_conflict([skewed_early, skewed_late]) == skewed_late
      assert Field.resolve_conflict([skewed_late, skewed_early]) == skewed_late

      # If tolerance is disabled (0 ms), raw earliest timestamp wins
      assert Field.resolve_conflict([skewed_early, skewed_late], 0) == skewed_early
    end

    test "lexicographical client_id breaks simultaneous timestamp ties deterministically" do
      t = 5000
      claim_a = %{client_id: "client_alpha", user_id: "u1", acquired_at: t, field: "name"}
      claim_z = %{client_id: "client_zebra", user_id: "u2", acquired_at: t, field: "name"}

      assert Field.resolve_conflict([claim_a, claim_z]) == claim_a
      assert Field.resolve_conflict([claim_z, claim_a]) == claim_a
    end
  end

  describe "extract_locks/1" do
    test "extracts locks across users and ignores users not editing" do
      presence_data = %{
        "user_1" => %{
          metas: [
            %{
              client_id: "c1",
              user_id: "user_1",
              user_name: "Alice",
              field: "customer.name",
              acquired_at: 100
            }
          ]
        },
        "user_2" => %{
          metas: [
            %{
              client_id: "c2",
              user_id: "user_2",
              user_name: "Bob",
              field: nil,
              acquired_at: 0
            }
          ]
        }
      }

      locks = Field.extract_locks(presence_data)
      assert Map.has_key?(locks, "customer.name")
      assert locks["customer.name"].user_name == "Alice"
      assert map_size(locks) == 1
    end

    test "resolves concurrent claims on the same field deterministically" do
      presence_data = %{
        "alice" => %{
          metas: [
            %{
              client_id: "c_alice",
              user_id: "alice",
              user_name: "Alice",
              field: "billing.street",
              acquired_at: 200
            }
          ]
        },
        "bob" => %{
          metas: [
            %{
              client_id: "c_bob",
              user_id: "bob",
              user_name: "Bob",
              field: "billing.street",
              acquired_at: 150
            }
          ]
        }
      }

      locks = Field.extract_locks(presence_data)
      # Bob acquired at 150 < 200, so Bob wins
      assert locks["billing.street"].user_name == "Bob"
      assert locks["billing.street"].client_id == "c_bob"
    end
  end

  describe "locked_by_other?/3" do
    setup do
      locks = %{
        "name" => %{client_id: "client_1", user_name: "Alice", field: "name"}
      }

      {:ok, locks: locks}
    end

    test "returns false if field is not locked", %{locks: locks} do
      refute Field.locked_by_other?(locks, "email", "client_1")
    end

    test "returns false if field is locked by the same client", %{locks: locks} do
      refute Field.locked_by_other?(locks, "name", "client_1")
    end

    test "returns true if field is locked by another client", %{locks: locks} do
      assert Field.locked_by_other?(locks, "name", "client_2")
      assert Field.locked_by_other?(locks, "name", nil)
    end
  end

  describe "validate_not_locked/5 changeset helper" do
    test "adds an error if field is locked by another client" do
      locks = %{
        "customer_name" => %{
          client_id: "c_alice",
          user_name: "Alice",
          field: "customer_name"
        }
      }

      changeset = %{errors: []}

      updated =
        Field.validate_not_locked(changeset, :customer_name, locks, "c_bob")

      assert [{:customer_name, {"is currently being edited by Alice", []}}] = updated.errors
    end

    test "does not add error if field is unlocked or held by same client" do
      locks = %{
        "customer_name" => %{
          client_id: "c_alice",
          user_name: "Alice",
          field: "customer_name"
        }
      }

      changeset = %{errors: []}

      assert %{errors: []} =
               Field.validate_not_locked(changeset, :customer_name, locks, "c_alice")

      assert %{errors: []} = Field.validate_not_locked(changeset, :email, locks, "c_bob")
    end
  end
end
