defmodule TWeb.MatchLive.Index do
  use TWeb, :live_view
  alias T.{Accounts, Matches, Feeds, Repo}
  alias TWeb.Presence

  @pubsub T.PubSub

  @impl true
  def mount(%{"user_id" => user_id}, _session, socket) do
    me = user_id |> Accounts.get_user!() |> Repo.preload(:profile)
    matches = Matches.get_current_matches(user_id)

    socket =
      if connected?(socket) do
        # {:ok, _} = Presence.track(self(), "matches:#{me.id}", me.id, %{})
        Matches.subscribe_for_user(me.id)
        Feeds.subscribe_for_likes(me.id)

        for match <- matches do
          mate_id = mate_id(match, me.id)

          {:ok, _} = Presence.track(self(), topic(mate_id), me.id, %{})

          TWeb.Endpoint.subscribe(topic(me.id))

          Matches.subscribe_for_match(match.id)
        end

        assign(socket,
          feed: Feeds.demo_feed(me.profile, fakes_count: 20),
          likers: all_likers(me.id)
        )
      else
        assign(socket, feed: [], likers: [])
      end

    {:ok,
     assign(socket,
       page_title: me.profile.name,
       me_id: me.id,
       me: me,
       matches: matches,
       user_options: user_options(),
       presences: presences(topic(me.id))
     ), temporary_assigns: [feed: [], likers: []]}
  end

  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       me_id: nil,
       me: nil,
       matches: [],
       feed: [],
       likers: [],
       user_options: user_options(),
       presences: []
     ), temporary_assigns: [feed: [], likers: []]}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(params, socket.assigns.live_action, socket)}
  end

  defp apply_action(%{"mate_id" => mate_id}, :call, socket) do
    if connected?(socket) do
      %{me: me, presences: presences} = socket.assigns

      if mate_id in presences do
        if socket.assigns[:call] do
          socket
        end
      end || push_patch(socket, to: Routes.match_index_path(socket, :show, me.id), replace: true)
    else
      socket
    end
  end

  defp apply_action(_params, _action, socket) do
    me = socket.assigns.me

    case socket.assigns[:call] do
      nil ->
        socket

      {s, mate} when s in [:calling, :called, :picked_up] ->
        Phoenix.PubSub.broadcast!(@pubsub, topic(mate), {:hang_up, me.id})
        assign(socket, call: nil)
    end
  end

  @impl true
  def handle_event("pick-user", %{"user" => user_id}, socket) do
    path = Routes.match_index_path(socket, :show, user_id)
    {:noreply, push_redirect(socket, to: path)}
  end

  def handle_event("unmatch", %{"match" => match_id}, socket) do
    me = socket.assigns.me
    {:ok, _} = Matches.unmatch_and_unhide(user: me.id, match: match_id)
    {:noreply, socket}
  end

  def handle_event("like", %{"user" => user_id}, socket) do
    me = socket.assigns.me
    {:ok, _} = Feeds.like_profile(me.id, user_id)
    {:noreply, socket}
  end

  def handle_event("call", %{"user" => user_id}, socket) do
    me = socket.assigns.me
    Phoenix.PubSub.broadcast!(@pubsub, topic(user_id), {:call, me.id})
    socket = assign(socket, call: {:calling, user_id})
    path = Routes.match_index_path(socket, :call, me.id, user_id)
    {:noreply, push_patch(socket, to: path)}
  end

  def handle_event("yo", %{"match" => match_id}, socket) do
    me = socket.assigns.me
    Matches.send_yo(match: match_id, from: me.id)
    {:noreply, socket}
  end

  def handle_event("pick-up", _params, socket) do
    %{call: {_state, mate}, me: me} = socket.assigns
    Phoenix.PubSub.broadcast!(@pubsub, topic(mate), {:pick_up, me.id})
    {:noreply, assign(socket, call: {:picked_up, mate})}
  end

  def handle_event("hang-up", _params, socket) do
    %{call: {_state, mate}, me: me} = socket.assigns
    Phoenix.PubSub.broadcast!(@pubsub, topic(mate), {:hang_up, me.id})
    path = Routes.match_index_path(socket, :show, me.id)
    {:noreply, socket |> assign(call: nil) |> push_patch(to: path)}
  end

  def handle_event("disconnected", _params, socket) do
    me = socket.assigns.me
    path = Routes.match_index_path(socket, :show, me.id)
    {:noreply, socket |> assign(call: nil) |> push_patch(to: path)}
  end

  def handle_event("peer-message" = event, %{"body" => _body, "mate" => mate} = params, socket) do
    TWeb.Endpoint.broadcast!(topic(mate), event, Map.delete(params, "mate"))
    {:noreply, socket}
  end

  def handle_event("peer-message" = event, %{"body" => _body} = params, socket) do
    {:picked_up, mate} = socket.assigns.call
    TWeb.Endpoint.broadcast!(topic(mate), event, params)
    {:noreply, socket}
  end

  def handle_event("ice-servers", _params, socket) do
    {:reply, %{ice_servers: T.Twilio.ice_servers()}, socket}
  end

  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    me = socket.assigns.me
    presences = presences(topic(me.id))

    socket =
      case socket.assigns[:call] do
        nil ->
          socket

        # even though peer might disconnect from backend, webrtc session might still be going on
        # so we rely on webrtc js hook to send `disconnected` event
        {:picked_up, _mate} ->
          socket

        {s, mate} when s in [:calling, :called] ->
          if mate in presences do
            socket
          else
            push_patch(socket, to: Routes.match_index_path(socket, :show, me.id))
          end
      end

    {:noreply, assign(socket, presences: presences)}
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{event: "peer-message" = event, payload: payload},
        socket
      ) do
    {:noreply, push_event(socket, event, payload)}
  end

  def handle_info({Matches, [:matched, match_id], user_ids}, socket) do
    %{me: me, matches: matches} = socket.assigns

    %Matches.Match{} = match = Matches.get_match_for_user(match_id, me.id)
    Matches.subscribe_for_match(match.id)

    mate_id = mate_id(user_ids, me.id)
    # TODO doesn't seem to work
    {:ok, _} = Presence.track(self(), topic(mate_id), me.id, %{})

    {:noreply, assign(socket, matches: [match | matches])}
  end

  def handle_info({Matches, [:unmatched, match_id], user_ids}, socket) do
    %{me: me, matches: matches} = socket.assigns
    matches = Enum.reject(matches, &(&1.id == match_id))

    Matches.unsubscribe_from_match(match_id)

    mate_id = mate_id(user_ids, me.id)
    Presence.untrack(self(), topic(mate_id), me.id)

    {:noreply, assign(socket, matches: matches)}
  end

  def handle_info({Feeds, :liked, _liker_id}, socket) do
    me = socket.assigns.me
    {:noreply, assign(socket, likers: all_likers(me.id))}
  end

  def handle_info({:call, mate}, socket) do
    me = socket.assigns.me

    socket =
      case socket.assigns[:call] do
        nil ->
          path = Routes.match_index_path(socket, :call, me.id, mate)

          socket
          |> assign(call: {:called, mate})
          |> push_patch(to: path)

        {:calling, ^mate} ->
          Phoenix.PubSub.broadcast!(@pubsub, topic(mate), {:pick_up, me.id})

          socket
          # |> maybe_push_want_offer(mate, me.id)
          |> assign(call: {:picked_up, mate})

        {s, _mate} when s in [:calling, :called, :picked_up] ->
          # ignore?
          socket
      end

    {:noreply, socket}
  end

  def handle_info({:pick_up, mate}, socket) do
    # me = socket.assigns.me

    socket =
      case socket.assigns[:call] do
        {:calling, ^mate} ->
          socket
          # |> maybe_push_want_offer(mate, me.id)
          |> assign(call: {:picked_up, mate})

        _other ->
          socket
      end

    {:noreply, socket}
  end

  def handle_info({:hang_up, mate}, socket) do
    me = socket.assigns.me

    socket =
      case socket.assigns[:call] do
        {s, ^mate} when s in [:calling, :called, :picked_up] ->
          push_patch(socket, to: Routes.match_index_path(socket, :show, me.id))

        {s, _other_mate} when s in [:calling, :called, :picked_up] ->
          socket

        nil ->
          socket
      end

    {:noreply, socket}
  end

  # def handle_info({:want_offer, mate}, socket) do
  #   socket =
  #     case socket.assigns[:call] do
  #       {:picked_up, ^mate} ->
  #         IO.inspect("pushing event")
  #         push_event(socket, "want-offer", %{mate: mate})

  #       _other ->
  #         socket
  #     end

  #   {:noreply, socket}
  # end

  # defp maybe_push_want_offer(socket, mate, me) do
  #   IO.inspect(["maybe offer", mate, me])

  #   if mate < me do
  #     IO.inspect(["offer", mate, me])
  #     push_event(socket, "want-offer", %{mate: mate})
  #   else
  #     IO.inspect("not pushing")
  #     Phoenix.PubSub.broadcast!(@pubsub, topic(mate), {:want_offer, me})
  #     socket
  #   end
  # end

  import Ecto.Query

  defp user_options do
    Accounts.User
    |> join(:inner, [u], p in Accounts.Profile, on: u.id == p.user_id)
    |> Ecto.Query.select([_, p], {p.name, p.user_id})
    |> order_by([_, p], desc: p.times_liked)
    |> Repo.all()
  end

  # defp all_profiles(me_id) do
  #   Accounts.Profile
  #   |> where([p], p.user_id != ^me_id)
  #   |> Repo.all()
  # end

  defp all_likers(me_id) do
    likers =
      Feeds.ProfileLike
      |> where(user_id: ^me_id)
      |> Ecto.Query.select([l], l.by_user_id)

    Accounts.Profile
    |> where([p], p.user_id in subquery(likers))
    |> Repo.all()
  end

  defp mate_id(%Matches.Match{user_id_1: uid1, user_id_2: uid2}, my_id) do
    mate_id([uid1, uid2], my_id)
  end

  defp mate_id([_, _] = user_ids, my_id) do
    [mate_id] = user_ids -- [my_id]
    mate_id
  end

  defp topic(user_id) do
    "matches:#{user_id}"
  end

  defp presences(topic) do
    topic |> Presence.list() |> Map.keys()
  end
end
