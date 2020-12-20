defmodule TWeb.UserAuth do
  import Plug.Conn
  import Phoenix.Controller

  alias T.Accounts

  # Make the remember me cookie valid for 60 days.
  # If you want bump or reduce this value, also change
  # the token expiry itself in UserToken.
  @max_age 60 * 60 * 24 * 60
  @remember_me_cookie "_t_web_user_remember_me"
  @remember_me_options [sign: true, max_age: @max_age, same_site: "Lax"]

  @doc """
  Logs the user in.

  It renews the session ID and clears the whole session
  to avoid fixation attacks. See the renew_session
  function to customize this behaviour.

  It also sets a `:live_socket_id` key in the session,
  so LiveView sessions are identified and automatically
  disconnected on log out. The line can be safely removed
  if you are not using LiveView.
  """
  def log_in_user(conn, user, params \\ %{}) do
    token = Accounts.generate_user_session_token(user)

    conn
    |> renew_session()
    |> put_session(:user_token, token)
    # |> put_session(:live_socket_id, "users_sessions:#{Base.url_encode64(token)}")
    |> maybe_write_remember_me_cookie(token, params)
    |> send_resp(200, [])
  end

  # defp maybe_write_remember_me_cookie(conn, token, %{"remember_me" => "true"}) do
  #   put_resp_cookie(conn, @remember_me_cookie, token, @remember_me_options)
  # end

  defp maybe_write_remember_me_cookie(conn, token, _params) do
    put_resp_cookie(conn, @remember_me_cookie, token, @remember_me_options)
  end

  # defp maybe_write_remember_me_cookie(conn, _token, _params) do
  #   conn
  # end

  # This function renews the session ID and erases the whole
  # session to avoid fixation attacks. If there is any data
  # in the session you may want to preserve after log in/log out,
  # you must explicitly fetch the session data before clearing
  # and then immediately set it after clearing, for example:
  #
  #     defp renew_session(conn) do
  #       preferred_locale = get_session(conn, :preferred_locale)
  #
  #       conn
  #       |> configure_session(renew: true)
  #       |> clear_session()
  #       |> put_session(:preferred_locale, preferred_locale)
  #     end
  #
  defp renew_session(conn) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  @doc """
  Logs the user out.

  It clears all session data for safety. See renew_session.
  """
  def log_out_user(conn) do
    user_token = get_session(conn, :user_token)
    user_token && Accounts.delete_session_token(user_token)

    # if live_socket_id = get_session(conn, :live_socket_id) do
    # TWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    # TODO
    TWeb.Endpoint.broadcast("user_socket:#{user_token.user_id}", "disconnect", %{})
    # end

    conn
    |> renew_session()
    |> delete_resp_cookie(@remember_me_cookie)
    |> send_resp(200, [])
  end

  @doc """
  Authenticates the user by looking into the session
  and remember me token.
  """
  def fetch_current_user(conn, _opts) do
    {user_token, conn} = ensure_user_token(conn)
    user = user_token && Accounts.get_user_by_session_token(user_token)
    assign(conn, :current_user, user)
  end

  defp ensure_user_token(conn) do
    if user_token = get_session(conn, :user_token) do
      {user_token, conn}
    else
      conn = fetch_cookies(conn, signed: [@remember_me_cookie])

      if user_token = conn.cookies[@remember_me_cookie] do
        {user_token, put_session(conn, :user_token, user_token)}
      else
        {nil, conn}
      end
    end
  end

  @doc """
  Used for routes that require the user to not be authenticated.
  """
  def require_not_authenticated_user(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
      |> put_status(400)
      |> json(%{detail: "You are already authenticated."})
      |> halt()
    else
      conn
    end
  end

  @doc """
  Used for routes that require the user to be authenticated.

  If you want to enforce the user phone number is confirmed before
  they use the application at all, here would be a good place.
  """
  def require_authenticated_user(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> put_status(401)
      |> json(%{detail: "You must log in to access this resource."})
      |> halt()
    end
  end
end
