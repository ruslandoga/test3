defmodule T.Accounts.DeletionTest do
  use T.DataCase, async: true
  use Oban.Testing, repo: Repo
  alias T.{Accounts, Feeds, Matches}

  describe "delete_user/1" do
    setup do
      %{profile: profile} = user = onboarded_user()
      {:ok, user: user, profile: profile}
    end

    test "deleted_at is set and phone number is updated", %{user: user} do
      refute user.deleted_at

      assert {:ok, %{delete_sessions: [], delete_user: nil, hide_profile: nil, unmatch: []}} =
               Accounts.delete_user(user.id)

      user = Repo.get(Accounts.User, user.id)
      assert user.deleted_at
      assert String.contains?(user.phone_number, "-DELETED-")
    end

    test "profile is hidden", %{profile: profile} do
      assert profile.hidden? == false

      assert {:ok, %{delete_sessions: [], delete_user: nil, hide_profile: nil, unmatch: []}} =
               Accounts.delete_user(profile.user_id)

      assert Repo.get(Accounts.Profile, profile.user_id).hidden?
    end

    test "sessions are deleted", %{user: user} do
      assert <<_::32-bytes>> = token = Accounts.generate_user_session_token(user, "mobile")
      assert [%Accounts.UserToken{token: ^token}] = Repo.all(Accounts.UserToken)

      assert {:ok, %{delete_sessions: [^token], delete_user: nil, hide_profile: nil, unmatch: []}} =
               Accounts.delete_user(user.id)

      assert [] == Repo.all(Accounts.UserToken)
    end

    test "current match is unmatched", %{user: user} do
      %{user_id: p2_id} = p2 = insert(:profile)

      Matches.subscribe_for_user(user.id)
      Matches.subscribe_for_user(p2.user_id)

      assert {:ok, %{match: nil}} = Feeds.like_profile(p2.user_id, user.id)

      assert {:ok, %{match: %Matches.Match{id: match_id, alive?: true}}} =
               Feeds.like_profile(user.id, p2.user_id)

      assert_receive {Matches, [:matched, ^match_id], [_, _] = user_ids}
      assert_receive {Matches, [:matched, ^match_id], ^user_ids}

      Matches.subscribe_for_match(match_id)

      assert {:ok,
              %{
                delete_sessions: [],
                delete_user: nil,
                hide_profile: nil,
                unmatch: [ok: %{unhide: [^p2_id], unmatch: ^user_ids}]
              }} = Accounts.delete_user(user.id)

      assert_receive {Matches, [:unmatched, ^match_id], ^user_ids}
    end

    test "full deletion job is scheduled", %{user: user} do
      assert {:ok, %{delete_sessions: [], delete_user: nil, hide_profile: nil, unmatch: []}} =
               Accounts.delete_user(user.id)

      assert_enqueued(worker: Accounts.UserDeletionJob, args: %{user_id: user.id})
    end
  end
end
