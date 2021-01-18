defmodule T.MatchesTest do
  use T.DataCase, async: true
  alias T.Accounts.Profile
  alias T.Matches
  alias Matches.{Match, Message}

  describe "unmatch" do
    test "match no longer, hidden no longer, heartbreak broadcasted" do
      [p1, p2] = insert_list(2, :profile, hidden?: true)

      %Match{id: match_id} =
        insert(:match, user_id_1: p1.user_id, user_id_2: p2.user_id, alive?: true)

      assert %Match{id: ^match_id} = Matches.get_current_match(p1.user_id)
      assert %Match{id: ^match_id} = Matches.get_current_match(p2.user_id)

      Matches.subscribe(match_id)

      assert {:ok, _changes} = Matches.unmatch(p1.user_id, match_id)

      assert_receive {Matches, :unmatched}

      refute Repo.get(Profile, p1.user_id).hidden?
      refute Repo.get(Profile, p2.user_id).hidden?

      refute Matches.get_current_match(p1.user_id)
      refute Matches.get_current_match(p2.user_id)
    end
  end

  describe "add_message" do
    setup do
      [p1, p2] = insert_list(2, :profile, hidden?: true)
      match = insert(:match, user_id_1: p1.user_id, user_id_2: p2.user_id, alive?: true)
      {:ok, match: match, profiles: [p1, p2]}
    end

    test "empty", %{match: match, profiles: [me | _not_me]} do
      assert {:error, changeset} = Matches.add_message(match.id, me.user_id, %{})
      assert errors_on(changeset) == %{data: ["can't be blank"], kind: ["can't be blank"]}
    end

    test "text kind", %{match: match, profiles: [me | _not_me]} do
      assert {:error, changeset} = Matches.add_message(match.id, me.user_id, %{"kind" => "text"})
      assert errors_on(changeset) == %{data: ["can't be blank"]}

      assert {:error, changeset} =
               Matches.add_message(match.id, me.user_id, %{"kind" => "text", "data" => %{}})

      assert errors_on(changeset) == %{text: ["can't be blank"]}

      assert {:ok, %Message{kind: "text", data: %{"text" => "hey"}}} =
               Matches.add_message(match.id, me.user_id, %{
                 "kind" => "text",
                 "data" => %{"text" => "hey"}
               })

      assert {:ok, %Message{kind: "markdown", data: %{"text" => "*hey*"}}} =
               Matches.add_message(match.id, me.user_id, %{
                 "kind" => "markdown",
                 "data" => %{"text" => "*hey*"}
               })

      assert {:ok, %Message{kind: "emoji", data: %{"text" => "😴"}}} =
               Matches.add_message(match.id, me.user_id, %{
                 "kind" => "emoji",
                 "data" => %{"text" => "😴"}
               })
    end

    test "media kind", %{match: match, profiles: [me | _not_me]} do
      assert {:error, changeset} = Matches.add_message(match.id, me.user_id, %{"kind" => "photo"})
      assert errors_on(changeset) == %{data: ["can't be blank"]}

      assert {:error, changeset} =
               Matches.add_message(match.id, me.user_id, %{"kind" => "photo", "data" => %{}})

      assert errors_on(changeset) == %{s3_key: ["can't be blank"]}

      assert {:ok, %Message{kind: "photo", data: %{"s3_key" => "hey"}}} =
               Matches.add_message(match.id, me.user_id, %{
                 "kind" => "photo",
                 "data" => %{"s3_key" => "hey"}
               })

      assert {:ok, %Message{kind: "audio", data: %{"s3_key" => "hey"}}} =
               Matches.add_message(match.id, me.user_id, %{
                 "kind" => "audio",
                 "data" => %{"s3_key" => "hey"}
               })

      assert {:ok, %Message{kind: "video", data: %{"s3_key" => "hey"}}} =
               Matches.add_message(match.id, me.user_id, %{
                 "kind" => "video",
                 "data" => %{"s3_key" => "hey"}
               })
    end

    test "location kind", %{match: match, profiles: [me | _not_me]} do
      assert {:error, changeset} =
               Matches.add_message(match.id, me.user_id, %{"kind" => "location"})

      assert errors_on(changeset) == %{data: ["can't be blank"]}

      assert {:error, changeset} =
               Matches.add_message(match.id, me.user_id, %{"kind" => "location", "data" => %{}})

      assert errors_on(changeset) == %{lat: ["can't be blank"], lon: ["can't be blank"]}

      assert {:ok, %Message{kind: "location", data: %{"lat" => 50.0, "lon" => 50.0}}} =
               Matches.add_message(match.id, me.user_id, %{
                 "kind" => "location",
                 "data" => %{"lat" => 50.0, "lon" => 50.0}
               })
    end
  end

  describe "list_messages" do
    setup do
      [p1, p2] = insert_list(2, :profile, hidden?: true)
      match = insert(:match, user_id_1: p1.user_id, user_id_2: p2.user_id, alive?: true)
      texts = ["oh, hey", "hey hey", "wow wow", "nice hey", "wow well", "yep yeah"]

      messages =
        Enum.map(texts, fn text ->
          {:ok, message} =
            Matches.add_message(match.id, p1.user_id, %{
              "kind" => "text",
              "data" => %{"text" => text}
            })

          message
        end)

      {:ok, match: match, profiles: [p1, p2], messages: messages}
    end

    test "with after: message_id", %{match: match, messages: messages} do
      [_m1, _m2, m3, m4, m5, m6] = Enum.map(messages, & &1.id)

      assert [] == Matches.list_messages(match.id, after: m6)

      assert [%Message{id: ^m6}] = Matches.list_messages(match.id, after: m5)
      assert [%Message{id: ^m5}, %Message{id: ^m6}] = Matches.list_messages(match.id, after: m4)

      assert [%Message{id: ^m4}, %Message{id: ^m5}, %Message{id: ^m6}] =
               Matches.list_messages(match.id, after: m3)
    end

    test "without after: message_id", %{match: match, messages: messages} do
      [m1, m2, m3, m4, m5, m6] = Enum.map(messages, & &1.id)
      assert [m1, m2, m3, m4, m5, m6] == match.id |> Matches.list_messages() |> Enum.map(& &1.id)
    end
  end
end