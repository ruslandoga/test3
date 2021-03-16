defmodule T.Feeds do
  @moduledoc "Feeds and liking feeds"
  import Ecto.{Query, Changeset}

  alias T.{Repo, Matches}
  alias T.Accounts.Profile
  alias T.Feeds.{Feed, SeenProfile, ProfileLike, PersonalityOverlap}

  @pubsub T.PubSub
  @topic to_string(__MODULE__)

  defp pubsub_likes_topic(user_id) when is_binary(user_id) do
    @topic <> ":l:" <> String.downcase(user_id)
  end

  def subscribe_for_likes(user_id) do
    Phoenix.PubSub.subscribe(@pubsub, pubsub_likes_topic(user_id))
  end

  defp notify_subscribers(
         {:ok, %{like: %ProfileLike{by_user_id: from, user_id: to}}} = success,
         :liked = event
       ) do
    msg = {__MODULE__, event, from}
    Phoenix.PubSub.broadcast(@pubsub, pubsub_likes_topic(to), msg)
    success
  end

  defp notify_subscribers({:error, _field, _reason, _changes} = error, _event) do
    error
  end

  defp notify_subscribers({:error, _reason} = error, _event) do
    error
  end

  ######################### LIKE #########################

  # TODO forbid liking if more than 3 active matches? or rather if hidden?
  # TODO auth, check they are in our feed, check no more than 5 per day
  def like_profile(by_user_id, user_id) do
    Ecto.Multi.new()
    # |> mark_seen(by_user_id, user_id)
    |> mark_liked(by_user_id, user_id)
    |> bump_likes_count(user_id)
    |> Matches.match_if_mutual_m(by_user_id, user_id)
    |> Repo.transaction()
    |> Matches.maybe_notify_of_match()
    |> notify_subscribers(:liked)
  end

  # defp mark_seen(multi, by_user_id, user_id) do
  #   changeset =
  #     %SeenProfile{by_user_id: by_user_id, user_id: user_id}
  #     |> change()
  #     |> unique_constraint(:seen, name: :seen_profiles_pkey)

  #   Ecto.Multi.insert(multi, :seen, changeset)
  # end

  defp mark_liked(multi, by_user_id, user_id) do
    changeset =
      %ProfileLike{by_user_id: by_user_id, user_id: user_id}
      |> change()
      |> unique_constraint(:like, name: :liked_profiles_pkey)

    Ecto.Multi.insert(multi, :like, changeset)
  end

  defp bump_likes_count(multi, user_id) do
    Ecto.Multi.run(multi, :bump_likes, fn _repo, _changes ->
      {1, [count]} =
        Profile
        |> where(user_id: ^user_id)
        |> select([p], p.times_liked)
        |> Repo.update_all(inc: [times_liked: 1])

      {:ok, count}
    end)
  end

  ######################### FEED #########################

  def get_or_create_feed(%Profile{} = profile, date \\ Date.utc_today(), opts \\ []) do
    f = fn -> get_feed(profile, date, opts) || create_feed(profile, date) end
    {:ok, profiles} = Repo.transaction(f)
    Enum.shuffle(profiles)
  end

  def use_demo_feed(use?) when is_boolean(use?) do
    Application.put_env(:t, :use_demo_feed?, use?)
  end

  def use_demo_feed? do
    !!Application.get_env(:t, :use_demo_feed?)
  end

  @doc "demo_feed(profile, loaded: 13) or demo_feed(next_ids, loaded: 13)"
  def demo_feed(profile_or_next_ids, opts \\ [])

  def demo_feed(%{user_id: user_id} = _profile, opts) do
    first_real = "00000177-679a-ad79-0242-ac1100030000"

    real =
      Profile
      |> where([p], p.user_id != ^user_id)
      |> where([p], p.user_id >= ^first_real)
      |> select([p], p.user_id)
      |> Repo.all()
      |> Enum.shuffle()

    fakes =
      Profile
      |> where([p], p.user_id < ^first_real)
      |> where([p], p.gender == "F")
      |> select([p], p.user_id)
      # |> order_by([p], desc: p.user_id)
      |> Repo.all()
      |> Enum.shuffle()

    ids = real ++ fakes
    demo_feed(ids, opts)
  end

  def demo_feed(next_ids, opts) when is_list(next_ids) do
    loaded_count = opts[:loaded] || 10
    {to_fetch, next_ids} = Enum.split(next_ids, loaded_count)
    loaded = Profile |> where([p], p.user_id in ^to_fetch) |> Repo.all()
    %{loaded: loaded, next_ids: next_ids}
  end

  defp get_feed(profile, date, opts) do
    feed =
      Feed
      |> where(user_id: ^profile.user_id)
      |> where(date: ^date)
      |> Repo.one()

    if feed, do: load_users_for_feed(feed, profile, date, opts)
  end

  # TODO test seen profiles are not loaded
  defp load_users_for_feed(%Feed{profiles: profiles}, profile, _date, opts)
       when is_map(profiles) do
    q = where(Profile, [p], p.user_id in ^Map.keys(profiles))

    q =
      if opts[:keep_seen?] do
        q
      else
        seen = SeenProfile |> where(by_user_id: ^profile.user_id) |> select([s], s.user_id)
        where(q, [p], p.user_id not in subquery(seen))
      end

    profiles =
      q
      |> Repo.all()
      |> Enum.map(fn profile ->
        %Profile{profile | feed_reason: profiles[profile.user_id]}
      end)

    # len = length(profiles)

    # if len == 5 do
    profiles
    # else
    #   profiles ++ create_feed(5 - len, profile, date)
    # end
  end

  defp with_reason(profiles, reason) do
    Enum.map(profiles, fn profile -> %Profile{profile | feed_reason: reason} end)
  end

  # TODO optimise query
  defp create_feed(profile, date) do
    seen = SeenProfile |> where(by_user_id: ^profile.user_id) |> select([s], s.user_id)

    common_q =
      Profile
      # not self
      |> where([p], p.user_id != ^profile.user_id)
      |> where(hidden?: false)
      |> where(city: ^profile.city)
      # TODO is there a better way?
      |> where([p], p.user_id not in subquery(seen))

    common_q =
      if gender = opposite_gender(profile) do
        where(common_q, gender: ^gender)
      else
        common_q
      end

    # place_1 and place_2
    most_liked =
      common_q
      |> order_by([p], desc: p.times_liked)
      |> limit(2)
      |> Repo.all()
      |> with_reason("most liked")

    filter_out_ids = Enum.map(most_liked, & &1.user_id)

    most_overlap =
      common_q
      |> join(:inner, [p], po in PersonalityOverlap,
        on:
          (p.user_id == po.user_id_1 and po.user_id_2 == ^profile.user_id) or
            (p.user_id == po.user_id_2 and po.user_id_1 == ^profile.user_id)
      )
      |> order_by([p, po], desc: po.score)
      |> where([p], p.user_id not in ^filter_out_ids)
      |> limit(1)
      |> Repo.all()
      |> with_reason("most overlap")

    filter_out_ids = filter_out_ids ++ Enum.map(most_overlap, & &1.user_id)

    likers =
      common_q
      |> join(:inner, [p], pl in ProfileLike,
        on: p.user_id == pl.by_user_id and pl.user_id == ^profile.user_id
      )
      |> join(:left, [p, pl], po in PersonalityOverlap,
        on:
          (p.user_id == po.user_id_1 and pl.by_user_id == po.user_id_2) or
            (p.user_id == po.user_id_2 and pl.by_user_id == po.user_id_1)
      )
      |> order_by([..., po], desc_nulls_last: po.score)
      |> where([p], p.user_id not in ^filter_out_ids)
      |> limit(2)
      |> Repo.all()
      |> with_reason("has liked with (possible) overlap")

    filter_out_ids = filter_out_ids ++ Enum.map(likers, & &1.user_id)

    non_rated =
      common_q
      |> where([p], p.times_liked == 0)
      |> where([p], p.user_id not in ^filter_out_ids)
      |> join(:left, [p], po in PersonalityOverlap,
        on:
          (p.user_id == po.user_id_1 and po.user_id_2 == ^profile.user_id) or
            (p.user_id == po.user_id_2 and po.user_id_1 == ^profile.user_id)
      )
      |> order_by([p, po], desc_nulls_last: po.score)
      |> limit(2)
      |> Repo.all()
      |> with_reason("non rated with (possible) overlap")

    filter_out_ids = filter_out_ids ++ Enum.map(non_rated, & &1.user_id)

    filler =
      case non_rated do
        [_, _] ->
          non_rated

        [_] ->
          non_rated ++
            (common_q
             |> where([p], p.user_id not in ^filter_out_ids)
             |> limit(1)
             |> Repo.all()
             |> with_reason("random"))

        [] ->
          common_q
          |> where([p], p.user_id not in ^filter_out_ids)
          |> limit(2)
          |> Repo.all()
          |> with_reason("random")
      end

    rest =
      case likers do
        [_place_4, _place_5] -> likers
        [place_4] -> [place_4, List.first(filler)]
        [] -> filler
      end

    profiles = most_liked ++ most_overlap ++ rest

    {:ok, _feed} =
      Repo.insert(%Feed{
        user_id: profile.user_id,
        date: date,
        profiles:
          Map.new(profiles, fn %Profile{user_id: id, feed_reason: reason} -> {id, reason} end)
      })

    profiles
  end

  # TODO
  defp opposite_gender(%Profile{gender: gender}), do: opposite_gender(gender)
  defp opposite_gender("F"), do: "M"
  defp opposite_gender("M"), do: "F"
  defp opposite_gender(nil), do: nil
end
