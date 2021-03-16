defmodule TWeb.FeedChannelTest do
  use TWeb.ChannelCase
  alias T.{Feeds, Matches}

  setup do
    me = onboarded_user()
    {:ok, me: me, socket: connected_socket(me)}
  end

  # TODO reporting

  describe "join" do
    test "and get feed", %{socket: socket, me: %{profile: me}} do
      profiles = insert_list(20, :profile, gender: "F", city: me.city)

      [_place1 | [_2 | _rest]] = most_liked(profiles, 30..15)
      [_3 | [place4 | _rest]] = personality_overlap(profiles, me, 30..10)
      assert {:ok, %{match: nil}} = Feeds.like_profile(place4.user_id, me.user_id)

      assert {:ok, %{feed: feed}, _socket} =
               subscribe_and_join(socket, "feed:" <> me.user_id, %{"timezone" => "Europe/Moscow"})

      #  assert length(feed ) ==5
      assert length(feed) == 10
    end
  end

  # TODO do auth check
  describe "like profile" do
    setup [:with_other_profile, :subscribe_and_join]

    setup %{socket: socket, me: me} do
      {:ok, _reply, _socket} = subscribe_and_join(socket, "matches:#{me.id}")
      :ok
    end

    test "no prev like -> no match", %{socket: socket, me: me, profile: p} do
      ref = push(socket, "like", %{"profile_id" => p.user_id})

      assert_reply ref, :ok, reply, 1000
      assert reply == %{}

      assert [] == Matches.get_current_matches(me.id)
      refute_push "matched", _payload
    end

    test "has prev like -> match", %{socket: socket, me: me, profile: p} do
      assert {:ok, _prev_like = %{match: nil}} = Feeds.like_profile(p.user_id, me.id)
      ref = push(socket, "like", %{"profile_id" => p.user_id})

      assert_reply ref, :ok, reply, 1000
      assert reply == %{}
      assert_push "matched", %{match: %{last_active: last_active}} = payload
      assert [%{id: match_id}] = Matches.get_current_matches(me.id)
      assert %DateTime{} = last_active

      assert payload == %{
               match: %{
                 id: match_id,
                 online: false,
                 last_active: last_active,
                 profile: %{
                   song: nil,
                   birthdate: nil,
                   city: nil,
                   first_date_idea: nil,
                   free_form: nil,
                   gender: "F",
                   height: nil,
                   interests: [],
                   job: nil,
                   major: nil,
                   most_important_in_life: nil,
                   name: nil,
                   occupation: nil,
                   photos: [],
                   tastes: %{},
                   university: nil,
                   user_id: p.user_id
                 }
               }
             }
    end
  end

  defp with_other_profile(_context) do
    {:ok, profile: insert(:profile, gender: "F")}
  end

  defp subscribe_and_join(%{me: me, socket: socket}) do
    assert {:ok, _reply, socket} =
             subscribe_and_join(socket, "feed:" <> me.id, %{"timezone" => "Europe/Moscow"})

    {:ok, socket: socket}
  end
end
