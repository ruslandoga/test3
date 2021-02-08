defmodule TWeb.ProfileChannel do
  use TWeb, :channel
  alias T.Accounts.Profile
  alias T.Accounts
  alias TWeb.{ErrorView, ProfileView}

  @impl true
  def join("profile:" <> user_id, _params, socket) do
    ChannelHelpers.verify_user_id(socket, user_id)
    %Profile{} = profile = Accounts.get_profile!(socket.assigns.current_user)
    {:ok, %{profile: render_profile(profile)}, assign(socket, uploads: %{}, profile: profile)}
  end

  defp render_profile(profile) do
    render(ProfileView, "show.json", profile: profile)
  end

  @impl true
  def handle_in("upload-preflight", %{"media" => params}, socket) do
    "image/" <> _rest =
      content_type =
      case params do
        %{"content-type" => content_type} -> content_type
        %{"extension" => extension} -> MIME.type(extension)
      end

    {:ok, %{"key" => key} = fields} = Accounts.photo_upload_form(content_type)
    url = Accounts.photo_s3_url()

    uploads = socket.assigns.uploads
    socket = assign(socket, uploads: Map.put(uploads, key, nil))

    # TODO check key afterwards
    {:reply, {:ok, %{url: url, key: key, fields: fields}}, socket}
  end

  def handle_in("get-me", _params, socket) do
    %Profile{} = profile = Accounts.get_profile!(socket.assigns.current_user)
    {:reply, {:ok, %{profile: render_profile(profile)}}, assign(socket, profile: profile)}
  end

  def handle_in("submit", %{"profile" => params}, socket) do
    %{profile: profile, current_user: user} = socket.assigns

    # TODO check photos exist in s3
    f =
      if Accounts.user_onboarded?(user.id) do
        fn -> Accounts.update_profile(profile, params) end
      else
        fn -> Accounts.onboard_profile(profile, params) end
      end

    case f.() do
      {:ok, profile} ->
        {:reply, {:ok, %{profile: render_profile(profile)}}, socket}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:reply, {:error, %{profile: render(ErrorView, "changeset.json", changeset: changeset)}},
         socket}
    end
  end

  # TODO test
  def handle_in("delete-account", _payload, socket) do
    %{current_user: user} = socket.assigns
    {:ok, %{delete_sessions: tokens}} = Accounts.delete_user(user.id)

    for token <- tokens do
      encoded = Accounts.UserToken.encoded_token(token)
      TWeb.Endpoint.broadcast("user_socket:#{encoded}", "disconnect", %{})
    end

    {:reply, :ok, socket}
  end

  # TODO store current step in assigns and ask for transition to the next step?
  # def handle_in("validate", %{"step" => step}, socket) do
  #   validation =
  #     case step do
  #       "photos" ->
  #         # TODO ensure provided keys exist on s3 and have been generated by this process
  #         fn profile -> Accounts.validate_profile_photos(profile) end

  #       "general-info" ->
  #         fn profile -> Accounts.validate_profile_general_info(profile) end

  #       "work-and-education" ->
  #         fn profile -> Accounts.validate_profile_work_and_education(profile) end

  #       "about" ->
  #         fn profile -> Accounts.validate_profile_about(profile) end

  #       "tastes" ->
  #         fn profile -> Accounts.validate_profile_tastes(profile) end

  #       # TODO we can close the channel now
  #       "final" ->
  #         fn profile -> Accounts.finish_onboarding(profile.user_id) end
  #     end

  #   run_and_reply(socket, validation)
  # end

  # defp run_and_reply(socket, fun) do
  #   case fun.(socket.assigns.profile) do
  #     {:ok, profile} ->
  #       socket = assign(socket, profile: profile)
  #       {:reply, {:ok, %{profile: render_profile(profile)}}, socket}

  #     {:error, changeset} ->
  #       {:reply, {:error, render(ErrorView, "changeset.json", changeset: changeset)}, socket}
  #   end
  # end
end
