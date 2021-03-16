defmodule TWeb.FeedChannel do
  use TWeb, :channel
  alias TWeb.ProfileView
  alias T.{Feeds, Accounts}

  @impl true
  def join("feed:" <> user_id, %{"timezone" => timezone} = params, socket) do
    user_id = String.downcase(user_id)
    ChannelHelpers.verify_user_id(socket, user_id)

    # ChannelHelpers.ensure_onboarded(socket)

    datetime = local_datetime_now(timezone)
    schedule_feed_refresh_at_midnight(datetime, timezone)
    %Accounts.Profile{} = my_profile = Accounts.get_profile!(socket.assigns.current_user)

    # if Feeds.use_demo_feed?() do
    %{loaded: feed, next_ids: next_ids} =
      Feeds.demo_feed(my_profile, loaded: params["count"] || 10)

    # else
    # Feeds.get_or_create_feed(my_profile, DateTime.to_date(datetime))
    # end

    {:ok, %{feed: render_profiles(feed), own_profile: render_profile(my_profile)},
     assign(socket, timezone: timezone, profile: my_profile, next_ids: next_ids)}
  end

  @impl true
  def handle_in("like", %{"profile_id" => profile_id}, socket) do
    # TODO verify_can_see_profile(socket, profile_id)
    user = socket.assigns.current_user
    Feeds.like_profile(user.id, profile_id)
    {:reply, :ok, socket}
  end

  def handle_in("more", %{"count" => count}, socket) do
    %{next_ids: next_ids} = socket.assigns
    %{loaded: feed, next_ids: next_ids} = Feeds.demo_feed(next_ids, loaded: count)
    {:reply, {:ok, %{feed: render_profiles(feed)}, assign(socket, next_ids: next_ids)}}
  end

  def handle_in("report", %{"report" => report}, socket) do
    ChannelHelpers.report(socket, report)
  end

  @impl true
  # TODO test
  def handle_info({__MODULE__, [:update_feed], date}, socket) do
    %{timezone: timezone, current_user: user} = socket.assigns

    profile = Accounts.get_profile!(user)
    feed = Feeds.get_or_create_feed(profile, date)
    schedule_feed_refresh_at_midnight(local_datetime_now(timezone), timezone)
    push(socket, "feed:update", %{feed: render_profiles(feed)})

    {:noreply, socket}
  end

  #### MISC ####

  defp local_datetime_now(timezone) do
    DateTime.shift_zone!(DateTime.utc_now(), timezone)
  end

  defp mindnight_next_day(date, timezone) do
    DateTime.new(date, Time.new!(0, 0, 0), timezone)
  end

  # TODO extract and test
  defp schedule_feed_refresh_at_midnight(datetime_now, timezone) do
    next_day = datetime_now |> DateTime.to_date() |> Date.add(1)

    midnight_next_day =
      case mindnight_next_day(next_day, timezone) do
        {:ok, datetime} -> datetime
        {:ambiguous, _first_, second_dt} -> second_dt
        {:gap, _just_before, just_after} -> just_after
      end

    seconds_diff = DateTime.diff(midnight_next_day, datetime_now)
    msg = {__MODULE__, [:update_feed], next_day}
    Process.send_after(self(), msg, :timer.seconds(seconds_diff))
  end

  defp render_profile(profile) do
    render(ProfileView, "show.json", profile: profile)
  end

  defp render_profiles(profiles) do
    Enum.map(profiles, &render_profile/1)
  end
end
